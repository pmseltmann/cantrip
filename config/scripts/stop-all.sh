#!/usr/bin/env bash
#
# Stop all Cantrip bots and clean up
# Usage: ./stop-all.sh

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== Cantrip: Stopping System ==="
echo ""

if ! command -v tmux &> /dev/null; then
    echo "tmux not found. Nothing to stop."
    exit 0
fi

STOPPED=0

# Stop all workers (delegate to stop-worker.sh)
for worker_id in $(jq -r '.workers | keys[]' "$BOTS_JSON"); do
    SESSION_NAME="cantrip-$worker_id"
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        "$SCRIPT_DIR/stop-worker.sh" "$worker_id"
        STOPPED=$((STOPPED + 1))
    else
        echo "  $worker_id not running."
    fi
done

# Stop manager
SESSION_NAME="cantrip-manager"
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Stopping manager bot..."
    tmux kill-session -t "$SESSION_NAME" || echo "  WARNING: Failed to kill manager session"
    echo "  Manager stopped."
    STOPPED=$((STOPPED + 1))
else
    echo "  Manager not running."
fi

# Stop caffeinate
CAFFEINATE_PIDFILE="$CANTRIP_ROOT/.caffeinate.pid"
if [ -f "$CAFFEINATE_PIDFILE" ]; then
    PID=$(cat "$CAFFEINATE_PIDFILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "Stopping caffeinate (PID $PID)..."
        kill "$PID" 2>/dev/null || true
    fi
    rm -f "$CAFFEINATE_PIDFILE"
    echo "  caffeinate stopped."
fi

# Clean up launcher scripts
rm -f /tmp/cantrip-*-launch.sh

echo ""
echo "=== System stopped ($STOPPED sessions killed) ==="
