#!/usr/bin/env bash
#
# Start the Manager Bot and optionally all attuned workers
# Usage: ./start-all.sh
#
# Starts:
#   - Manager bot (always)
#   - Any workers that have an assigned_project in bots.json

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== Cantrip: Starting System ==="
echo ""

# Prevent Mac from sleeping while bots are running
CAFFEINATE_PIDFILE="$CANTRIP_ROOT/.caffeinate.pid"
if command -v caffeinate &> /dev/null; then
    # Kill any existing caffeinate from a previous run
    if [ -f "$CAFFEINATE_PIDFILE" ]; then
        OLD_PID=$(cat "$CAFFEINATE_PIDFILE")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            echo "Stopping previous caffeinate (PID $OLD_PID)..."
            kill "$OLD_PID" 2>/dev/null || true
        fi
        rm -f "$CAFFEINATE_PIDFILE"
    fi

    echo "Enabling caffeinate (preventing sleep)..."
    caffeinate -dims &
    echo $! > "$CAFFEINATE_PIDFILE"
    echo "caffeinate PID: $(cat "$CAFFEINATE_PIDFILE")"
    echo ""
fi

# Start manager
echo "--- Starting Manager Bot ---"
"$SCRIPT_DIR/start-manager.sh"
echo ""

# Start attuned workers
for worker_id in $(jq -r '.workers | keys[]' "$BOTS_JSON"); do
    project=$(jq -r ".workers[\"$worker_id\"].assigned_project // empty" "$BOTS_JSON")
    if [ -n "$project" ]; then
        echo "--- Attuning $worker_id → $project ---"
        "$SCRIPT_DIR/start-worker.sh" "$worker_id" "$project"
        echo ""
    else
        echo "--- $worker_id: idle (no attunement) ---"
    fi
done

echo ""
echo "=== System started ==="
echo "tmux sessions: tmux ls"
echo "Attach: tmux attach -t cantrip-<name>"
