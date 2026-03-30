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
if command -v caffeinate &> /dev/null; then
    echo "Enabling caffeinate (preventing sleep)..."
    caffeinate -dims &
    CAFFEINATE_PID=$!
    echo "caffeinate PID: $CAFFEINATE_PID (kill this to allow sleep again)"
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
