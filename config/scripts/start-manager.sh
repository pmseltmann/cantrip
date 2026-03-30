#!/usr/bin/env bash
#
# Start the Manager Bot for Cantrip
# Usage: ./start-manager.sh

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SESSION_NAME="cantrip-manager"
TOKEN=$(require_token "manager")
MANAGER_CHANNEL_ID=$(cfg_manager_channel_id)

SYSTEM_PROMPT="You are the Manager Bot for the Cantrip multi-agent system. Read CLAUDE.md immediately for your full instructions.

CRITICAL RULE: You MUST only respond to messages in the #manager channel (ID: $MANAGER_CHANNEL_ID). If a message arrives from ANY other channel (#project-1, #project-2, etc.), DO NOT RESPOND. Do not reply, do not acknowledge, do not send any message. Project channels are handled by worker bots. The ONLY exception is if someone explicitly @-mentions your name in another channel.

When you need to delegate work to a project channel, use the Discord reply tool to send a [TASK] message to that channel. But NEVER respond to general conversation in project channels."

echo "=== Cantrip Manager Bot ==="
echo "Working directory: $CANTRIP_ROOT"
echo ""

if ! command -v claude &> /dev/null; then
    echo "ERROR: 'claude' command not found."
    exit 1
fi

if command -v tmux &> /dev/null; then
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "Manager bot already running: $SESSION_NAME"
        echo "Attach: tmux attach -t $SESSION_NAME"
        exit 0
    fi

    echo "Starting manager bot in tmux session: $SESSION_NAME"
    tmux new-session -d -s "$SESSION_NAME" -c "$CANTRIP_ROOT" \
        "DISCORD_BOT_TOKEN=\"$TOKEN\" claude --channels plugin:discord@claude-plugins-official --dangerously-skip-permissions --append-system-prompt \"$SYSTEM_PROMPT\""

    echo "Manager bot started. Attach: tmux attach -t $SESSION_NAME"
else
    echo "tmux not found — running in foreground."
    cd "$CANTRIP_ROOT"
    DISCORD_BOT_TOKEN="$TOKEN" exec claude \
        --channels plugin:discord@claude-plugins-official \
        --dangerously-skip-permissions \
        --append-system-prompt "$SYSTEM_PROMPT"
fi
