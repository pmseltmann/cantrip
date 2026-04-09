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

You are subscribed only to the #manager channel (ID: $MANAGER_CHANNEL_ID). You will not receive messages from project channels — workers handle those autonomously.

When you need to delegate work to a project channel, use the Discord reply tool to send a [TASK] message to that channel (outbound sends work to any channel, regardless of subscription). To check on a project's progress, read its .memory/ files directly rather than expecting Discord messages."

HUMAN_USER_ID=$(cfg_human_user_id 2>/dev/null || echo "")

echo "=== Cantrip Manager Bot ==="
echo "Working directory: $CANTRIP_ROOT"
echo "Listening on channel: $MANAGER_CHANNEL_ID (#manager only)"
echo ""

if ! command -v claude &> /dev/null; then
    echo "ERROR: 'claude' command not found."
    exit 1
fi

# Pre-accept Claude Code trust dialog for headless operation
ensure_claude_trust "$CANTRIP_ROOT"

if command -v tmux &> /dev/null; then
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "Manager bot already running: $SESSION_NAME"
        echo "Attach: tmux attach -t $SESSION_NAME"
        exit 0
    fi

    # Write system prompt to a file (avoids shell quoting issues)
    PROMPT_FILE="/tmp/cantrip-manager-prompt.txt"
    printf '%s' "$SYSTEM_PROMPT" > "$PROMPT_FILE"

    LAUNCHER="/tmp/cantrip-manager-launch.sh"
    LOG="/tmp/cantrip-manager.log"

    cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
LAUNCHER_EOF
    echo "export DISCORD_BOT_TOKEN=$(printf '%q' "$TOKEN")" >> "$LAUNCHER"
    echo "export DISCORD_CHANNEL_IDS=$(printf '%q' "$MANAGER_CHANNEL_ID")" >> "$LAUNCHER"
    [ -n "$HUMAN_USER_ID" ] && echo "export DISCORD_ALLOWED_USERS=$(printf '%q' "$HUMAN_USER_ID")" >> "$LAUNCHER"
    cat >> "$LAUNCHER" <<LAUNCHER_EOF
echo "[\$(date)] Starting manager bot..." >> $(printf '%q' "$LOG")
exec claude \\
    --dangerously-load-development-channels server:cantrip-discord \\
    --permission-mode bypassPermissions \\
    --append-system-prompt-file $(printf '%q' "$PROMPT_FILE") \\
    2>> $(printf '%q' "$LOG")
LAUNCHER_EOF
    chmod +x "$LAUNCHER"

    echo "Starting manager bot in tmux session: $SESSION_NAME"
    tmux new-session -d -s "$SESSION_NAME" -c "$CANTRIP_ROOT" "$LAUNCHER"

    # Auto-accept any trust prompts (Enter to confirm defaults)
    sleep 3
    tmux send-keys -t "$SESSION_NAME" Enter 2>/dev/null || true
    sleep 2
    tmux send-keys -t "$SESSION_NAME" Enter 2>/dev/null || true
    sleep 2
    tmux send-keys -t "$SESSION_NAME" Enter 2>/dev/null || true

    # Check if the session survived
    sleep 3
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "Manager bot started. Attach: tmux attach -t $SESSION_NAME"
    else
        echo "ERROR: Manager session exited immediately."
        echo "Check log: cat $LOG"
        echo "Or run manually: bash $LAUNCHER"
        [ -f "$LOG" ] && echo "" && echo "=== Last 20 lines of log ===" && tail -20 "$LOG"
        exit 1
    fi
else
    echo "tmux not found — running in foreground."
    cd "$CANTRIP_ROOT"
    export DISCORD_BOT_TOKEN="$TOKEN"
    export DISCORD_CHANNEL_IDS="$MANAGER_CHANNEL_ID"
    [ -n "$HUMAN_USER_ID" ] && export DISCORD_ALLOWED_USERS="$HUMAN_USER_ID"
    exec claude \
        --dangerously-load-development-channels server:cantrip-discord \
        --dangerously-skip-permissions \
        --append-system-prompt "$SYSTEM_PROMPT"
fi
