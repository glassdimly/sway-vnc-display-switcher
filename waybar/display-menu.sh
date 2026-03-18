#!/bin/bash
# Waybar display-menu: rofi picker for output migration and VNC control.

# shellcheck source=../bin/_lib.sh
. "$(dirname "$(readlink -f "$0")")/../bin/_lib.sh" 2>/dev/null \
    || { CONF="${XDG_CONFIG_HOME:-$HOME/.config}/sway-vnc-display-switcher/conf"; [ -f "$CONF" ] && . "$CONF"; }

# If _lib.sh was sourced, load conf through it; otherwise defaults are already set above
type svds_load_conf &>/dev/null && svds_load_conf

# Ensure defaults for variables used in this script
PHYSICAL_OUTPUT="${PHYSICAL_OUTPUT:-HDMI-A-1}"
HEADLESS_OUTPUT="${HEADLESS_OUTPUT:-HEADLESS-1}"
KEY_MIGRATE_PHYSICAL="${KEY_MIGRATE_PHYSICAL:-Mod4+ctrl+d}"
KEY_MIGRATE_HEADLESS="${KEY_MIGRATE_HEADLESS:-Mod4+ctrl+n}"
VNC_LOG="${VNC_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/sway-vnc/vnc.log}"
WAYBAR_SIGNAL="${WAYBAR_SIGNAL:-8}"

OUTPUTS=$(swaymsg -t get_outputs 2>/dev/null)
WORKSPACES=$(swaymsg -t get_workspaces 2>/dev/null)

CURRENT=$(echo "$WORKSPACES" | python3 -c "
import sys, json
ws = json.load(sys.stdin)
focused = [w for w in ws if w['focused']]
print(focused[0]['output'] if focused else '')
")

VNC_RUNNING=$(pgrep -x wayvnc > /dev/null && echo "yes" || echo "no")

# Check if headless output exists (may have been destroyed by vnc-serve kill)
HEADLESS_EXISTS=$(echo "$OUTPUTS" | python3 -c "
import json, sys
try:
    outputs = json.load(sys.stdin)
    for o in outputs:
        if o['name'].startswith('HEADLESS-'):
            print('yes')
            sys.exit(0)
except Exception:
    pass
print('no')
")

# Build menu
MENU=$(CURRENT="$CURRENT" VNC_RUNNING="$VNC_RUNNING" HEADLESS_EXISTS="$HEADLESS_EXISTS" \
       PHYSICAL_OUTPUT="$PHYSICAL_OUTPUT" HEADLESS_OUTPUT="$HEADLESS_OUTPUT" \
       KEY_MIGRATE_PHYSICAL="$KEY_MIGRATE_PHYSICAL" KEY_MIGRATE_HEADLESS="$KEY_MIGRATE_HEADLESS" \
       python3 -c "
import json, sys, os
outputs = json.load(sys.stdin)
current = os.environ.get('CURRENT', '')
vnc = os.environ.get('VNC_RUNNING', 'no')
headless_exists = os.environ.get('HEADLESS_EXISTS', 'no')
physical = os.environ.get('PHYSICAL_OUTPUT', 'HDMI-A-1')
headless = os.environ.get('HEADLESS_OUTPUT', 'HEADLESS-1')
key_phys = os.environ.get('KEY_MIGRATE_PHYSICAL', 'Mod4+ctrl+d')
key_head = os.environ.get('KEY_MIGRATE_HEADLESS', 'Mod4+ctrl+n')
active = [o['name'] for o in outputs]
lines = []
known = {physical, headless}

def mark(name):
    return '  ✓ active' if name == current else ''

# Always show physical output
lines.append(f'󰍹  {physical}      ({key_phys}){mark(physical)}')
# Show headless with actual name from outputs if available
headless_name = next((o['name'] for o in outputs if o['name'].startswith('HEADLESS-')), headless)
lines.append(f'󰍹  {headless_name}    ({key_head}){mark(headless_name)}')
known.add(headless_name)
for name in active:
    if name not in known:
        lines.append(f'󰍹  {name}{mark(name)}')

lines.append('')
if vnc == 'yes':
    lines.append('󰢹  VNC  ✓ running')
    lines.append('󰅙  VNC  kill')
elif headless_exists == 'no':
    lines.append('󰢹  VNC  start (no headless)')
else:
    lines.append('󰢹  VNC  start')

print('\n'.join(lines))
" <<< "$OUTPUTS")

CHOICE=$(echo "$MENU" | rofi -dmenu -i -p "Display" -theme-str 'window { width: 400px; }')
[ -z "$CHOICE" ] && exit 0

if echo "$CHOICE" | grep -qF "$PHYSICAL_OUTPUT"; then
    ws-migrate hdmi
elif echo "$CHOICE" | grep -q "HEADLESS-"; then
    ws-migrate headless
elif echo "$CHOICE" | grep -q "VNC  kill"; then
    vnc-serve kill
elif echo "$CHOICE" | grep -q "VNC  start"; then
    mkdir -p "$(dirname "$VNC_LOG")"
    nohup vnc-serve start > "$VNC_LOG" 2>&1 &
    sleep 3  # allow headless creation + wayvnc startup
    pkill -RTMIN+"$WAYBAR_SIGNAL" waybar 2>/dev/null || true
else
    # Unknown/extra output — extract name and migrate manually
    OUTPUT=$(echo "$CHOICE" | awk '{print $2}')
    for i in 1 2 3 4 5 6 7 8 9 10; do
        swaymsg "[workspace=$i] move workspace to output $OUTPUT" 2>/dev/null || true
    done
    swaymsg "focus output $OUTPUT"
    wayvncctl output-set "$OUTPUT" 2>/dev/null || true
fi
