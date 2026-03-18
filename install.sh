#!/bin/bash
# sway-vnc-display-switcher — installer
#
# Guides you through configuring and installing the module components.
# Nothing is installed without a y prompt. Config files are never patched
# automatically — snippets are printed and optionally saved for manual merging.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sway-vnc-display-switcher"
CONF_FILE="$CONF_DIR/conf"
BIN_DIR="$CONF_DIR/bin"

# ── Terminal colors ───────────────────────────────────────────────────────────
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
DIM='\033[2m'
NC='\033[0m'

header() { echo -e "\n${BOLD}━━━ $1 ━━━${NC}"; }
ok()     { echo -e "  ${GREEN}✓${NC}  $1"; }
warn()   { echo -e "  ${YELLOW}!${NC}  $1"; }
info()   { echo -e "  ${BLUE}→${NC}  $1"; }
dim()    { echo -e "  ${DIM}$1${NC}"; }

# Ask a yes/no question. Returns 0 for yes, 1 for no.
ask_yn() {
    local msg="$1"
    local reply
    read -rp "  $msg [y/N] " reply
    [[ "${reply,,}" == "y" ]]
}

# Ask for a value with a default.
ask_val() {
    local prompt="$1"
    local default="$2"
    local val
    read -rp "  $prompt [${default}]: " val
    echo "${val:-$default}"
}

# Check if a command exists.
check_dep() {
    local cmd="$1" label="${2:-$1}"
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$label"
        return 0
    else
        warn "$label — not found"
        return 1
    fi
}

# Substitute all __PLACEHOLDER__ values in a template file using current vars.
apply_template() {
    local file="$1"
    sed \
        -e "s|__PHYSICAL_OUTPUT__|${PHYSICAL_OUTPUT}|g" \
        -e "s|__HEADLESS_OUTPUT__|${HEADLESS_OUTPUT}|g" \
        -e "s|__MONITOR_DESC__|${MONITOR_DESC}|g" \
        -e "s|__MONITOR_RES__|${MONITOR_RES}|g" \
        -e "s|__TERMINAL__|${TERMINAL}|g" \
        -e "s|__DROPDOWN_SHELL__|${DROPDOWN_SHELL}|g" \
        -e "s|__KEY_MIGRATE_PHYSICAL__|${KEY_MIGRATE_PHYSICAL}|g" \
        -e "s|__KEY_MIGRATE_HEADLESS__|${KEY_MIGRATE_HEADLESS}|g" \
        -e "s|__KEY_DROPDOWN__|${KEY_DROPDOWN}|g" \
        -e "s|__WAYBAR_SIGNAL__|${WAYBAR_SIGNAL}|g" \
        "$file"
}

# Copy a script to destination with optional backup.
copy_script() {
    local src="$1" dst="$2"
    if [ -f "$dst" ]; then
        cp "$dst" "$dst.bak"
        warn "Backed up existing file → $dst.bak"
    fi
    cp "$src" "$dst"
    chmod +x "$dst"
    ok "Installed $dst"
}

# Print a snippet and offer to save it to /tmp.
show_snippet() {
    local title="$1" file="$2" dest_hint="$3"
    local tmp rendered
    tmp=$(mktemp "/tmp/svds-$(basename "$file").XXXXXX")
    rendered=$(apply_template "$file")
    echo ""
    echo -e "  ${BOLD}── Merge into $dest_hint ──────────────────────────────────────────${NC}"
    echo ""
    echo "$rendered" | sed 's/^/    /'
    echo ""
    # Warn about any placeholders that were not substituted
    if echo "$rendered" | grep -qF '__'; then
        warn "The following placeholders are still blank (update conf and re-run):"
        echo "$rendered" | grep -oE '__[A-Z_]+__' | sort -u | while IFS= read -r p; do
            warn "  $p"
        done
        echo ""
    fi
    if ask_yn "Save this snippet to $tmp?"; then
        echo "$rendered" > "$tmp"
        ok "Saved to $tmp"
    else
        rm -f "$tmp"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}sway-vnc-display-switcher — installer${NC}"
echo ""
echo "  Guides you through installing the module components."
echo "  Each step is optional. Nothing is written without a y prompt."
echo "  Config files (sway, waybar, kanshi) are never patched automatically —"
echo "  snippets are printed and saved for you to merge."

# ── Step 1: Configuration ─────────────────────────────────────────────────────
header "Step 1: Configuration"

# Load existing conf as defaults if present
# shellcheck source=/dev/null
[ -f "$CONF_FILE" ] && source "$CONF_FILE"

echo ""
echo "  We'll ask a few questions to configure the module."
echo "  Press Enter to accept the [default]."
echo ""
dim "Find output names:        swaymsg -t get_outputs | python3 -m json.tool | grep '\"name\"'"
dim "Find monitor description: swaymsg -t get_outputs | python3 -m json.tool | grep '\"description\"'"
echo ""

PHYSICAL_OUTPUT=$(ask_val "Physical output name (your monitor)"              "${PHYSICAL_OUTPUT:-HDMI-A-1}")
HEADLESS_OUTPUT=$(ask_val "Headless virtual output name"                     "${HEADLESS_OUTPUT:-HEADLESS-1}")
PHYSICAL_POS=$(ask_val    "Physical output position (x y)"                  "${PHYSICAL_POS:-0 0}")
HEADLESS_POS=$(ask_val    "Headless output position (x y)"                  "${HEADLESS_POS:-2560 0}")
VNC_ADDR=$(ask_val        "VNC bind address"                                 "${VNC_ADDR:-127.0.0.1}")
VNC_PORT=$(ask_val        "VNC port"                                         "${VNC_PORT:-5900}")
VNC_SSH_HOST=$(ask_val    "SSH host for connect hint  (user@hostname)"       "${VNC_SSH_HOST:-user@hostname}")
WAYBAR_SIGNAL=$(ask_val   "Waybar signal number"                             "${WAYBAR_SIGNAL:-8}")
TERMINAL=$(ask_val        "Terminal emulator  (must support --class flag)"   "${TERMINAL:-kitty}")
DROPDOWN_SHELL=$(ask_val  "Shell for dropdown terminal"                      "${DROPDOWN_SHELL:-${SHELL:-/bin/bash}}")
KEY_MIGRATE_PHYSICAL=$(ask_val "Keybinding: migrate to physical output"      "${KEY_MIGRATE_PHYSICAL:-Mod4+ctrl+d}")
KEY_MIGRATE_HEADLESS=$(ask_val "Keybinding: migrate to headless output"      "${KEY_MIGRATE_HEADLESS:-Mod4+ctrl+n}")
KEY_DROPDOWN=$(ask_val    "Keybinding: toggle dropdown terminal"             "${KEY_DROPDOWN:-Control+Shift+Space}")
MONITOR_DESC=$(ask_val    "Monitor description for kanshi (blank = later)"   "${MONITOR_DESC:-}")
MONITOR_RES=$(ask_val     "Physical monitor resolution"                      "${MONITOR_RES:-2560x1440}")
HEADLESS_RES=$(ask_val    "Headless virtual output resolution"               "${HEADLESS_RES:-$MONITOR_RES}")
VNC_LOG=$(ask_val         "Log file for background vnc-serve"                "${VNC_LOG:-/tmp/sway-vnc-display-switcher.log}")
KVM_USB_HUB=$(ask_val     "KVM USB hub path (blank = disable USB detection)" "${KVM_USB_HUB:-}")

# Keep DROPDOWN_WIDTH/HEIGHT from existing conf or use defaults
DROPDOWN_WIDTH="${DROPDOWN_WIDTH:-100ppt}"
DROPDOWN_HEIGHT="${DROPDOWN_HEIGHT:-65ppt}"

echo ""
if ask_yn "Write configuration to $CONF_FILE?"; then
    mkdir -p "$CONF_DIR"
    cat > "$CONF_FILE" << EOF
# sway-vnc-display-switcher configuration
# Generated by install.sh — edit as needed.

PHYSICAL_OUTPUT="${PHYSICAL_OUTPUT}"
HEADLESS_OUTPUT="${HEADLESS_OUTPUT}"
PHYSICAL_POS="${PHYSICAL_POS}"
HEADLESS_POS="${HEADLESS_POS}"
VNC_ADDR="${VNC_ADDR}"
VNC_PORT="${VNC_PORT}"
VNC_SSH_HOST="${VNC_SSH_HOST}"
VNC_LOG="${VNC_LOG}"
WAYBAR_SIGNAL="${WAYBAR_SIGNAL}"
TERMINAL="${TERMINAL}"
DROPDOWN_SHELL="${DROPDOWN_SHELL}"
DROPDOWN_WIDTH="${DROPDOWN_WIDTH}"
DROPDOWN_HEIGHT="${DROPDOWN_HEIGHT}"
KEY_MIGRATE_PHYSICAL="${KEY_MIGRATE_PHYSICAL}"
KEY_MIGRATE_HEADLESS="${KEY_MIGRATE_HEADLESS}"
KEY_DROPDOWN="${KEY_DROPDOWN}"
MONITOR_DESC="${MONITOR_DESC}"
MONITOR_RES="${MONITOR_RES}"
HEADLESS_RES="${HEADLESS_RES}"
KVM_USB_HUB="${KVM_USB_HUB}"
EOF
    ok "Configuration written to $CONF_FILE"
fi

# ── Step 2: Core scripts ──────────────────────────────────────────────────────
header "Step 2: Core scripts  (vnc-serve + ws-migrate + output-watcher + dropdown + kanshi-start + sway-vnc-apply)"

echo "  Scripts install to $BIN_DIR — a self-contained tree under the config dir."
echo "  Checking dependencies..."
check_dep sway
check_dep wayvnc
check_dep wayvncctl
check_dep kanshi
check_dep python3
check_dep udevadm "udevadm (for KVM USB detection)"
check_dep envsubst "envsubst (for kanshi config generation)"
echo ""

mkdir -p "$BIN_DIR"
ask_yn "Copy vnc-serve      → $BIN_DIR/vnc-serve?"      && copy_script "$SCRIPT_DIR/bin/vnc-serve"      "$BIN_DIR/vnc-serve"
ask_yn "Copy ws-migrate     → $BIN_DIR/ws-migrate?"     && copy_script "$SCRIPT_DIR/bin/ws-migrate"     "$BIN_DIR/ws-migrate"
ask_yn "Copy output-watcher → $BIN_DIR/output-watcher?" && copy_script "$SCRIPT_DIR/bin/output-watcher" "$BIN_DIR/output-watcher"
ask_yn "Copy dropdown.sh    → $BIN_DIR/dropdown.sh?"    && copy_script "$SCRIPT_DIR/bin/dropdown.sh"    "$BIN_DIR/dropdown.sh"
ask_yn "Copy kanshi-start   → $BIN_DIR/kanshi-start?"   && copy_script "$SCRIPT_DIR/bin/kanshi-start"   "$BIN_DIR/kanshi-start"
ask_yn "Copy sway-vnc-apply → $BIN_DIR/sway-vnc-apply?" && copy_script "$SCRIPT_DIR/bin/sway-vnc-apply" "$BIN_DIR/sway-vnc-apply"

# Install kanshi template
TMPL_DIR="$CONF_DIR/templates"
mkdir -p "$TMPL_DIR"
if ask_yn "Copy kanshi.template → $TMPL_DIR/kanshi.template?"; then
    if [ -f "$TMPL_DIR/kanshi.template" ]; then
        cp "$TMPL_DIR/kanshi.template" "$TMPL_DIR/kanshi.template.bak"
        warn "Backed up existing file → $TMPL_DIR/kanshi.template.bak"
    fi
    cp "$SCRIPT_DIR/templates/kanshi.template" "$TMPL_DIR/kanshi.template"
    ok "Installed $TMPL_DIR/kanshi.template"
fi

# ── Step 2b: PATH setup ───────────────────────────────────────────────────────
header "Step 2b: PATH setup"

echo "  Scripts live in $BIN_DIR."
echo "  This directory must be on your PATH for sway exec_always and keybindings to work."
echo ""

ZSHENV="$HOME/.zshenv"
PATH_ENTRY='export PATH="$HOME/.config/sway-vnc-display-switcher/bin:$PATH"'

if grep -qF 'sway-vnc-display-switcher/bin' "$ZSHENV" 2>/dev/null; then
    ok "PATH entry already present in $ZSHENV"
else
    info "Suggested entry for $ZSHENV:"
    echo ""
    echo "    $PATH_ENTRY"
    echo ""
    if ask_yn "Add this PATH entry to $ZSHENV?"; then
        {
            echo ""
            echo "# sway-vnc-display-switcher scripts"
            echo "$PATH_ENTRY"
        } >> "$ZSHENV"
        ok "Added to $ZSHENV"
        warn "Source it in your current shell: source $ZSHENV"
    else
        warn "Skipped. Add the PATH entry manually before reloading sway."
    fi
fi

# ── Step 3: Sway config ───────────────────────────────────────────────────────
header "Step 3: Sway config  (one include line)"

echo "  sway-vnc-apply generates ~/.config/sway/sway-vnc.conf from your conf."
echo "  You only need to add one include line to ~/.config/sway/config:"
echo ""
info "    include ~/.config/sway/sway-vnc.conf"
echo ""
echo "  This replaces any hardcoded workspace assignments, migration keybindings,"
echo "  dropdown exec/rules/bindsym, and kanshi/vnc-serve/output-watcher exec_always."
echo "  Remove those sections from your sway config before adding the include line."
echo ""
if ask_yn "Run sway-vnc-apply now to generate sway-vnc.conf?"; then
    if command -v sway-vnc-apply >/dev/null 2>&1; then
        sway-vnc-apply
    elif [ -x "$BIN_DIR/sway-vnc-apply" ]; then
        "$BIN_DIR/sway-vnc-apply"
    else
        warn "sway-vnc-apply not found on PATH or at $BIN_DIR/sway-vnc-apply — install it first (Step 2)"
    fi
fi
echo ""

# ── Step 4: Dropdown terminal ─────────────────────────────────────────────────
header "Step 4: Dropdown terminal"

echo "  Quake-style scratchpad terminal. Output-agnostic — works on both outputs."
echo "  dropdown.sh was included in the core scripts install (Step 2)."
echo "  Window rules and the exec_always launch are generated into sway-vnc.conf"
echo "  automatically by sway-vnc-apply — no manual sway config entry needed."
echo ""
echo "  Checking dependencies..."
check_dep "$TERMINAL" "terminal ($TERMINAL)" || \
    warn "Set TERMINAL in conf to any emulator that supports --class"
echo ""

# ── Step 5: Waybar indicator ──────────────────────────────────────────────────
header "Step 5: Waybar display indicator  (optional)"

echo "  Shows the active output in the bar with teal/orange color coding."
echo "  Clicking opens the rofi display menu (Step 6)."
echo "  Checking dependencies..."
WAYBAR_OK=false
check_dep waybar && WAYBAR_OK=true
echo ""

WAYBAR_DONE=false
if $WAYBAR_OK && ask_yn "Install waybar display indicator?"; then
    mkdir -p "$HOME/.config/waybar"
    copy_script "$SCRIPT_DIR/waybar/display.sh" "$HOME/.config/waybar/display.sh"
    show_snippet "waybar config" "$SCRIPT_DIR/waybar/config.snippet.jsonc" "~/.config/waybar/config.jsonc"
    show_snippet "waybar style"  "$SCRIPT_DIR/waybar/style.snippet.css"    "~/.config/waybar/style.css"
    WAYBAR_DONE=true
fi

# ── Step 6: Rofi display menu ─────────────────────────────────────────────────
header "Step 6: Rofi display menu  (optional, requires Step 5)"

if ! $WAYBAR_DONE; then
    warn "Skipping — waybar indicator was not installed in Step 5."
else
    echo "  Click the waybar icon to open a rofi menu for output switching and VNC control."
    echo "  Checking dependencies..."
    check_dep rofi
    echo ""
    if ask_yn "Install rofi display menu?"; then
        copy_script "$SCRIPT_DIR/waybar/display-menu.sh" "$HOME/.config/waybar/display-menu.sh"
    fi
fi

# ── Step 7: Kanshi auto-switching ─────────────────────────────────────────────
header "Step 7: Kanshi auto-switching"

echo "  kanshi-start generates ~/.config/kanshi/config from templates/kanshi.template"
echo "  on every sway reload, using values from conf. DO NOT edit ~/.config/kanshi/config"
echo "  directly — it will be overwritten. Edit the template instead:"
info "    $TMPL_DIR/kanshi.template"
echo ""
echo "  kanshi-start is launched automatically via exec_always in sway-vnc.conf (Step 3)."
echo "  No manual sway config entry is needed."
echo ""
check_dep kanshi
echo ""

if [ -z "$MONITOR_DESC" ]; then
    warn "MONITOR_DESC is blank. Find your monitor description:"
    info "swaymsg -t get_outputs | python3 -m json.tool | grep '\"description\"'"
    echo "  Then update $CONF_FILE and re-run install.sh."
    echo ""
fi

# ── Next steps ────────────────────────────────────────────────────────────────
header "Next steps"

echo ""
echo "  1.  Edit your conf if anything looks wrong:"
info "    $CONF_FILE"
echo ""
echo "  2.  Add one include line to ~/.config/sway/config (remove any hardcoded"
echo "      workspace/dropdown/migration/exec_always sections first):"
info "    include ~/.config/sway/sway-vnc.conf"
echo ""
echo "  3.  Run sway-vnc-apply to (re)generate sway-vnc.conf, then reload sway:"
info "    sway-vnc-apply"
echo ""

if [ -z "$MONITOR_DESC" ]; then
    echo "  4.  Find your monitor description for kanshi:"
    info "    swaymsg -t get_outputs | python3 -m json.tool | grep '\"description\"'"
    echo "      Add it to $CONF_FILE as MONITOR_DESC, then re-run install.sh."
    echo ""
    NEXT=5
else
    NEXT=4
fi

echo "  $NEXT.  Restart waybar (if installed):"
info "    pkill waybar && waybar &"
echo ""
((NEXT++))
echo "  $NEXT.  Start VNC:"
info "    vnc-serve"
echo ""
((NEXT++))
echo "  $NEXT.  Connect from client — see client/connect.sh or client/ssh_config.snippet"
echo ""
