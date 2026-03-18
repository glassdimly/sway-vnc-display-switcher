#!/bin/bash
# _lib.sh — shared helpers for sway-vnc-display-switcher scripts
#
# Source this from any script:
#   . "$(dirname "$(readlink -f "$0")")/_lib.sh"
#
# Provides:
#   svds_load_conf     — load conf file with ownership check, set all defaults
#   svds_get_headless  — discover current HEADLESS-N name (state file → swaymsg)
#   svds_ensure_headless — create headless output if absent, discover name
#   svds_log           — timestamped log line (caller must set _LOG_FILE)

# Guard against double-sourcing
[[ -n "${_SVDS_LIB_LOADED:-}" ]] && return 0
_SVDS_LIB_LOADED=1

# ── State file path ───────────────────────────────────────────────────────────
_SVDS_HEADLESS_STATE="${XDG_RUNTIME_DIR:-/tmp}/sway-vnc-headless-name"

# ── svds_load_conf ────────────────────────────────────────────────────────────
# Load ~/.config/sway-vnc-display-switcher/conf with ownership check.
# Sets all variables to their defaults if not defined in conf.
svds_load_conf() {
    local _conf="${XDG_CONFIG_HOME:-$HOME/.config}/sway-vnc-display-switcher/conf"
    if [ -f "$_conf" ]; then
        if [ "$(stat -c %u "$_conf")" = "$(id -u)" ]; then
            # shellcheck source=/dev/null
            source "$_conf"
        else
            echo "Warning: $_conf not owned by current user — skipping" >&2
        fi
    fi

    # Defaults — every variable used by any script in the suite
    PHYSICAL_OUTPUT="${PHYSICAL_OUTPUT:-HDMI-A-1}"
    HEADLESS_OUTPUT="${HEADLESS_OUTPUT:-HEADLESS-1}"
    VNC_ADDR="${VNC_ADDR:-127.0.0.1}"
    VNC_PORT="${VNC_PORT:-5900}"
    VNC_SSH_HOST="${VNC_SSH_HOST:-user@hostname}"
    VNC_LOG="${VNC_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/sway-vnc/vnc.log}"
    WAYBAR_SIGNAL="${WAYBAR_SIGNAL:-8}"
    TERMINAL="${TERMINAL:-kitty}"
    DROPDOWN_SHELL="${DROPDOWN_SHELL:-/bin/bash}"
    DROPDOWN_WIDTH="${DROPDOWN_WIDTH:-80ppt}"
    DROPDOWN_HEIGHT="${DROPDOWN_HEIGHT:-80ppt}"
    KEY_MIGRATE_PHYSICAL="${KEY_MIGRATE_PHYSICAL:-Mod4+ctrl+d}"
    KEY_MIGRATE_HEADLESS="${KEY_MIGRATE_HEADLESS:-Mod4+ctrl+n}"
    KEY_DROPDOWN="${KEY_DROPDOWN:-Control+Shift+Space}"
    KEY_DROPDOWN_2="${KEY_DROPDOWN_2:-}"
    MONITOR_DESC="${MONITOR_DESC:-}"
    MONITOR_RES="${MONITOR_RES:-2560x1440}"
    HEADLESS_RES="${HEADLESS_RES:-2560x1440}"
    HEADLESS_SCALE="${HEADLESS_SCALE:-1}"
    PHYSICAL_POS="${PHYSICAL_POS:-0 0}"
    HEADLESS_POS="${HEADLESS_POS:-2560 0}"
    KVM_USB_HUB="${KVM_USB_HUB:-}"
    WS_MAX="${WS_MAX:-10}"

    # Sanitize numeric values
    [[ "$WAYBAR_SIGNAL" =~ ^[0-9]+$ ]] || WAYBAR_SIGNAL=8
    [[ "$WS_MAX" =~ ^[0-9]+$ ]] || WS_MAX=10
    [[ "$HEADLESS_SCALE" =~ ^[0-9]+$ ]] || HEADLESS_SCALE=1
}

# ── svds_get_headless ─────────────────────────────────────────────────────────
# Discover the current HEADLESS-N output name. Checks the state file first
# (fast path), then falls back to querying swaymsg. Writes the discovered
# name to the state file and exports HEADLESS_OUTPUT.
#
# If no headless output exists (e.g. after vnc-serve kill), HEADLESS_OUTPUT
# is set to empty string and the state file is removed.
svds_get_headless() {
    local name=""

    # Fast path: state file exists and names a live output
    if [ -f "$_SVDS_HEADLESS_STATE" ]; then
        name=$(cat "$_SVDS_HEADLESS_STATE" 2>/dev/null)
        if [ -n "$name" ] && swaymsg -t get_outputs 2>/dev/null | grep -qF "\"name\": \"$name\""; then
            HEADLESS_OUTPUT="$name"
            export HEADLESS_OUTPUT
            return 0
        fi
    fi

    # Slow path: query swaymsg for any HEADLESS-* output
    name=$(swaymsg -t get_outputs 2>/dev/null | python3 -c "
import json, sys
try:
    outputs = json.load(sys.stdin)
    for o in outputs:
        if o['name'].startswith('HEADLESS-'):
            print(o['name'])
            break
except Exception:
    pass
" 2>/dev/null)

    if [ -n "$name" ]; then
        echo "$name" > "$_SVDS_HEADLESS_STATE"
        HEADLESS_OUTPUT="$name"
    else
        rm -f "$_SVDS_HEADLESS_STATE"
        HEADLESS_OUTPUT=""
    fi
    export HEADLESS_OUTPUT
}

# ── svds_ensure_headless ──────────────────────────────────────────────────────
# Ensure a headless output exists. Creates one if absent, discovers its name,
# and writes the state file.
#
# After creation, if the name differs from conf's HEADLESS_OUTPUT default,
# regenerates sway-vnc.conf and kanshi config so all references use the new
# name. This handles the wlroots monotonic naming (HEADLESS-1 → HEADLESS-2
# after unplug/create).
svds_ensure_headless() {
    # First check if one already exists
    svds_get_headless
    if [ -n "$HEADLESS_OUTPUT" ]; then
        # Exists — make sure it's enabled
        swaymsg output "$HEADLESS_OUTPUT" enable 2>/dev/null || true
        return 0
    fi

    # Wait up to 2s in case it's briefly re-initializing (kanshi applying a
    # profile). Don't call create_output during this window — we'd get a
    # duplicate HEADLESS-N.
    local i
    for i in $(seq 1 10); do
        svds_get_headless
        [ -n "$HEADLESS_OUTPUT" ] && { swaymsg output "$HEADLESS_OUTPUT" enable 2>/dev/null || true; return 0; }
        sleep 0.2
    done

    # Truly absent — create it
    swaymsg create_output 2>/dev/null

    # Wait up to 2s for it to appear and discover the name
    for i in $(seq 1 10); do
        svds_get_headless
        [ -n "$HEADLESS_OUTPUT" ] && break
        sleep 0.2
    done

    if [ -z "$HEADLESS_OUTPUT" ]; then
        echo "svds_ensure_headless: failed to create headless output" >&2
        return 1
    fi

    # Apply mode/scale/position immediately so kanshi and wayvnc can use it
    swaymsg output "$HEADLESS_OUTPUT" enable mode "$HEADLESS_RES" scale "$HEADLESS_SCALE" 2>/dev/null || true

    return 0
}

# ── svds_log ──────────────────────────────────────────────────────────────────
# Timestamped log line. Caller must set _LOG_FILE before calling.
svds_log() {
    [ -n "${_LOG_FILE:-}" ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$_LOG_FILE"
}
