#!/usr/bin/env bash
#
# Show the status of all Cantrip bot sessions
# Usage: ./status.sh

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== Cantrip Bot Status ==="
echo ""

SESSIONS=("cantrip-manager" "cantrip-worker-1" "cantrip-worker-2" "cantrip-worker-3" "cantrip-worker-4")

for session in "${SESSIONS[@]}"; do
    if command -v tmux &> /dev/null && tmux has-session -t "$session" 2>/dev/null; then
        echo "  ✓ $session — RUNNING"
    else
        echo "  ✗ $session — STOPPED"
    fi
done

echo ""

# Show attunements from bots.json
echo "Familiar Attunements (from bots.json):"
for worker_id in $(jq -r '.workers | keys[]' "$BOTS_JSON"); do
    project=$(jq -r ".workers[\"$worker_id\"].assigned_project // \"(idle)\"" "$BOTS_JSON")
    status=$(jq -r ".workers[\"$worker_id\"].status // \"unknown\"" "$BOTS_JSON")
    echo "  $worker_id: $project ($status)"
done
