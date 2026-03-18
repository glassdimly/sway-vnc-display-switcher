#!/bin/bash
# connect.sh — open SSH tunnel to sway-vnc-display-switcher and connect VNC client
#
# Usage:
#   ./connect.sh [user@host] [local_port]
#
# Or set VNC_SSH_HOST and VNC_PORT in a local conf file:
#   ~/.config/sway-vnc-display-switcher/conf
#
# The tunnel forwards localhost:LOCAL_PORT → server:VNC_PORT over SSH.
# wayvnc binds to 127.0.0.1 only, so the SSH tunnel is required.

set -u

_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/sway-vnc-display-switcher/conf"
if [ -f "$_CONF" ]; then
    if [ "$(stat -c %u "$_CONF")" = "$(id -u)" ]; then
        # shellcheck source=/dev/null
        source "$_CONF"
    else
        echo "Warning: $_CONF not owned by current user — skipping" >&2
    fi
fi
unset _CONF

HOST="${1:-${VNC_SSH_HOST:-}}"
LOCAL_PORT="${2:-${VNC_PORT:-5900}}"
REMOTE_PORT="${VNC_PORT:-5900}"

if [ -z "$HOST" ] || [ "$HOST" = "user@hostname" ]; then
    echo "Error: no host configured." >&2
    echo "" >&2
    echo "Usage: $0 user@host [port]" >&2
    echo "" >&2
    echo "Or set VNC_SSH_HOST in:" >&2
    echo "  ${XDG_CONFIG_HOME:-$HOME/.config}/sway-vnc-display-switcher/conf" >&2
    exit 1
fi

# Check if something is already listening on the local port (portable: ss, fallback to nc)
port_in_use() {
    ss -tlnp 2>/dev/null | grep -qF ":${LOCAL_PORT} "
}

if port_in_use; then
    echo "Port $LOCAL_PORT is already in use — tunnel may already be open."
    echo "To find the process: ss -tlnp | grep :$LOCAL_PORT"
    echo ""
else
    echo "Opening SSH tunnel: $HOST → localhost:$LOCAL_PORT..."
    ssh -L "${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" -N "$HOST" &
    SSH_PID=$!
    disown "$SSH_PID"
    sleep 1
    if ! kill -0 "$SSH_PID" 2>/dev/null; then
        echo "SSH tunnel failed — process exited immediately." >&2
        exit 1
    fi
    echo "Tunnel open (PID: $SSH_PID)"
    echo "To close: kill $SSH_PID"
    echo ""
fi

echo "Connect your VNC client to:  localhost:$LOCAL_PORT"
echo ""
echo "Client connection examples:"
echo "  macOS (Screens, built-in Screen Sharing):"
echo "    open vnc://localhost:$LOCAL_PORT"
echo ""
echo "  Linux:"
echo "    xdg-open vnc://localhost:$LOCAL_PORT"
echo "    vncviewer localhost:$LOCAL_PORT          # TigerVNC"
