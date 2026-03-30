#!/usr/bin/env bash
#
# Stop a Worker Bot (Familiar)
# Usage: ./stop-worker.sh <worker-id>
#
# Example: ./stop-worker.sh worker-1

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <worker-id>"
    exit 1
fi

WORKER_ID="$1"
SESSION_NAME="cantrip-$WORKER_ID"

if [[ ! "$WORKER_ID" =~ ^worker-[1-4]$ ]]; then
    echo "ERROR: Invalid worker ID '$WORKER_ID'."
    exit 1
fi

if command -v tmux &> /dev/null && tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Stopping $WORKER_ID (tmux session: $SESSION_NAME)..."
    tmux kill-session -t "$SESSION_NAME"
    echo "$WORKER_ID stopped."
else
    echo "$WORKER_ID is not running."
fi
