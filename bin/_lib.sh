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
    KVM_USB_VID_PID="${KVM_USB_VID_PID:-}"
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

    # Wait for a headless output to appear via sway output events (e.g. kanshi
    # creating one during profile apply). subscribe without -m exits after the
    # first event; timeout handles the case where no event fires. Event payload
    # is just {"change":"unspecified"} so we check ground truth via get_headless.
    local _attempt
    for _attempt in 1 2 3 4 5; do
        timeout 0.5 swaymsg -t subscribe '["output"]' > /dev/null 2>&1 || true
        svds_get_headless
        [ -n "$HEADLESS_OUTPUT" ] && { swaymsg output "$HEADLESS_OUTPUT" enable 2>/dev/null || true; return 0; }
    done

    # Truly absent — create it
    swaymsg create_output 2>/dev/null

    # Wait for sway to process create_output — it fires exactly one output event.
    # Check immediately first (handles race where event fires before subscribe),
    # then subscribe if needed. timeout covers edge cases.
    svds_get_headless
    if [ -z "$HEADLESS_OUTPUT" ]; then
        timeout 2 swaymsg -t subscribe '["output"]' > /dev/null 2>&1 || true
        svds_get_headless
    fi

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

# ── svds_rotate_logs ──────────────────────────────────────────────────────────
# Rotate *.log files in the sway-vnc state directory.
# - If a rotated .log.1 exists, delete it (it's from the previous cycle).
# - If the active .log is older than 5 days (mtime), rename it to .log.1.
# Call from a long-lived process startup (e.g. output-watcher) so it runs
# on every sway reload without needing cron or a systemd timer.
svds_rotate_logs() {
    local _log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/sway-vnc"
    [ -d "$_log_dir" ] || return 0

    local _f
    for _f in "$_log_dir"/*.log; do
        [ -f "$_f" ] || continue

        # Delete previous rotation if it exists
        [ -f "${_f}.1" ] && rm -f "${_f}.1"

        # Rotate current log if older than 5 days
        if find "$_f" -mtime +5 -print -quit 2>/dev/null | grep -q .; then
            mv "$_f" "${_f}.1"
        fi
    done
}

# ── svds_resolve_usb_hub ──────────────────────────────────────────────────────
# Resolve KVM_USB_VID_PID (vendor:product) to a sysfs bus-port path and set
# KVM_USB_HUB. If KVM_USB_HUB is already set (manual override), skip.
# Returns 0 if resolved or already set, 1 if no device found.
#
# Example: VID_PID="05e3:0610" → KVM_USB_HUB="5-1"
#
# The sysfs path is the directory basename under /sys/bus/usb/devices/ whose
# idVendor and idProduct match. Only top-level hub entries (bus-port format,
# no colons or interface suffixes) are considered.
svds_resolve_usb_hub() {
    # Manual override takes precedence
    if [ -n "${KVM_USB_HUB:-}" ]; then
        return 0
    fi

    if [ -z "${KVM_USB_VID_PID:-}" ]; then
        return 1
    fi

    local vid pid dev devname
    vid="${KVM_USB_VID_PID%%:*}"
    pid="${KVM_USB_VID_PID##*:}"

    for dev in /sys/bus/usb/devices/*; do
        devname="${dev##*/}"
        # Skip interfaces (e.g. "5-1:1.0") and root hubs (e.g. "usb1")
        [[ "$devname" =~ ^[0-9]+-[0-9.]+$ ]] || continue
        [ -f "$dev/idVendor" ] || continue
        if [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$vid" ] && \
           [ "$(cat "$dev/idProduct" 2>/dev/null)" = "$pid" ]; then
            KVM_USB_HUB="$devname"
            export KVM_USB_HUB
            return 0
        fi
    done

    KVM_USB_HUB=""
    return 1
}
