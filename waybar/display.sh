#!/bin/bash
# Waybar custom/display status script
# Shows icon for the focused output; tooltip lists all outputs + keybindings

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/sway-vnc-display-switcher/conf"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
PHYSICAL_OUTPUT="${PHYSICAL_OUTPUT:-HDMI-A-1}"
HEADLESS_OUTPUT="${HEADLESS_OUTPUT:-HEADLESS-1}"
KEY_MIGRATE_PHYSICAL="${KEY_MIGRATE_PHYSICAL:-Super+Ctrl+D}"
KEY_MIGRATE_HEADLESS="${KEY_MIGRATE_HEADLESS:-Super+Ctrl+N}"

WORKSPACES=$(swaymsg -t get_workspaces 2>/dev/null)
OUTPUTS=$(swaymsg -t get_outputs 2>/dev/null)

FOCUSED_OUTPUT=$(echo "$WORKSPACES" | python3 -c "
import sys, json
ws = json.load(sys.stdin)
focused = [w for w in ws if w['focused']]
print(focused[0]['output'] if focused else '')
")

ALL_OUTPUTS=$(echo "$OUTPUTS" | python3 -c "
import sys, json
outputs = json.load(sys.stdin)
for o in outputs:
    if o.get('active'):
        print(o['name'])
" | sort)

if [ "$FOCUSED_OUTPUT" = "$PHYSICAL_OUTPUT" ]; then
    CLASS="hdmi"
else
    CLASS="headless"
fi
ICON="󰍹"

# Append vnc class if wayvnc is running
if pgrep -x wayvnc > /dev/null; then
    CLASS="$CLASS vnc"
fi

# Build tooltip: current output + all outputs + keybindings
TOOLTIP="Active: ${FOCUSED_OUTPUT:-unknown}"$'\n'
TOOLTIP+="Outputs: $(echo "$ALL_OUTPUTS" | tr '\n' ' ')"$'\n'
TOOLTIP+=$'\n'
TOOLTIP+="${KEY_MIGRATE_PHYSICAL}  →  ${PHYSICAL_OUTPUT}"$'\n'
TOOLTIP+="${KEY_MIGRATE_HEADLESS}  →  ${HEADLESS_OUTPUT}"

printf '{"text": "%s", "tooltip": "%s", "class": ["%s"]}\n' \
    "$ICON" \
    "$(echo "$TOOLTIP" | sed 's/"/\\"/g' | tr '\n' '\n' | python3 -c "import sys; print(sys.stdin.read().rstrip().replace(chr(10), r'\n'))")" \
    "$(echo "$CLASS" | sed 's/ /", "/g')"
