#!/bin/bash
# dropdown.sh — quake-style dropdown terminal toggle
#
# Always targets the currently focused workspace — output-agnostic.
# Works on PHYSICAL_OUTPUT (docked) and HEADLESS_OUTPUT (VNC) without special-casing.
#
# Three cases:
#   DROPDOWN_WS = ''         → in scratchpad      → show, then move to target WS
#   DROPDOWN_WS = TARGET_WS  → visible on target  → hide
#   DROPDOWN_WS = other      → visible elsewhere  → move to target WS

set -u

# shellcheck source=_lib.sh
. "$(dirname "$(readlink -f "$0")")/_lib.sh"
svds_load_conf

command -v python3 >/dev/null 2>&1 || { echo "Error: python3 is required" >&2; exit 1; }

# Launch if not running
if ! swaymsg -t get_tree | grep -qF '"app_id": "dropdown"'; then
    "$TERMINAL" --class dropdown "$DROPDOWN_SHELL" &
    # Poll until the window appears (up to 2s). Ground-truth check via get_tree
    # is more reliable than sway window subscribe (noisy events from all windows,
    # race condition if window appears before subscribe starts). 0.1s granularity
    # adds <100ms overhead — invisible for a UI action.
    for _i in $(seq 1 20); do
        swaymsg -t get_tree | grep -qF '"app_id": "dropdown"' && break
        sleep 0.1
    done
    unset _i
fi

WORKSPACES=$(swaymsg -t get_workspaces)

# Currently focused workspace number (output-agnostic) — use num to avoid injection
TARGET_WS_NUM=$(echo "$WORKSPACES" | python3 -c "
import sys, json
ws = json.load(sys.stdin)
focused = [w for w in ws if w['focused']]
print(focused[0]['num'] if focused else '')
")

if [ -z "$TARGET_WS_NUM" ] || ! [[ "$TARGET_WS_NUM" =~ ^[0-9]+$ ]]; then
    echo "dropdown.sh: no focused workspace" >&2
    exit 1
fi

# Returns workspace number if visible on a workspace, '' if in scratchpad
DROPDOWN_WS_NUM=$(swaymsg -t get_tree | python3 -c "
import sys, json
def find(node, ws_num=None):
    if node.get('type') == 'workspace' and node.get('name') != '__i3_scratch':
        ws_num = node.get('num')
    if node.get('app_id') == 'dropdown':
        return ws_num if ws_num is not None else ''
    for child in node.get('nodes', []) + node.get('floating_nodes', []):
        r = find(child, ws_num)
        if r is not None:
            return r
    return None
r = find(json.load(sys.stdin))
print(r if r is not None else '')
")

if [ -z "$DROPDOWN_WS_NUM" ]; then
    # In scratchpad — show then move to target workspace
    swaymsg '[app_id="dropdown"] scratchpad show'
    swaymsg "[app_id=\"dropdown\"] move container to workspace number $TARGET_WS_NUM, resize set width $DROPDOWN_WIDTH height $DROPDOWN_HEIGHT, move position 0 0"
elif [ "$DROPDOWN_WS_NUM" = "$TARGET_WS_NUM" ]; then
    # Visible on the target workspace — hide
    swaymsg '[app_id="dropdown"] move scratchpad'
else
    # Visible on a different workspace — move to target
    swaymsg "[app_id=\"dropdown\"] move container to workspace number $TARGET_WS_NUM, resize set width $DROPDOWN_WIDTH height $DROPDOWN_HEIGHT, move position 0 0"
fi
