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

# Build channel ID list: manager channel + all project channels
HUMAN_USER_ID=$(cfg_human_user_id 2>/dev/null || echo "")
ALL_CHANNEL_IDS="$MANAGER_CHANNEL_ID"
if [ -f "$BOTS_JSON" ]; then
    PROJECT_CHANNELS=$(jq -r '.projects | to_entries[] | .value.discord_channel_id // empty' "$BOTS_JSON" 2>/dev/null | tr '\n' ',')
    [ -n "$PROJECT_CHANNELS" ] && ALL_CHANNEL_IDS="$ALL_CHANNEL_IDS,$PROJECT_CHANNELS"
fi
# Remove trailing comma
ALL_CHANNEL_IDS="${ALL_CHANNEL_IDS%,}"

echo "=== Cantrip Manager Bot ==="
echo "Working directory: $CANTRIP_ROOT"
echo "Listening on channels: $ALL_CHANNEL_IDS"
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

    # Write a launcher script that auto-accepts the development channels
    # trust prompt via expect, then hands off to the interactive session.
    LAUNCHER="/tmp/cantrip-manager-launch.sh"
    LOG="/tmp/cantrip-manager.log"

    # First write a bash wrapper that sets env vars and calls expect
    cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
LAUNCHER_EOF
    echo "export DISCORD_BOT_TOKEN=$(printf '%q' "$TOKEN")" >> "$LAUNCHER"
    echo "export DISCORD_CHANNEL_IDS=$(printf '%q' "$ALL_CHANNEL_IDS")" >> "$LAUNCHER"
    [ -n "$HUMAN_USER_ID" ] && echo "export DISCORD_ALLOWED_USERS=$(printf '%q' "$HUMAN_USER_ID")" >> "$LAUNCHER"

    # Write the expect script that auto-accepts prompts
    EXPECT_SCRIPT="/tmp/cantrip-manager-expect.exp"
    cat > "$EXPECT_SCRIPT" <<EXPECTEOF
#!/usr/bin/env expect -f
set timeout 30
spawn claude \\
    --dangerously-load-development-channels server:cantrip-discord \\
    --permission-mode bypassPermissions \\
    --append-system-prompt $(printf '%q' "$SYSTEM_PROMPT")

# Auto-accept any yes/no prompts during startup (trust dialogs)
expect {
    -re {(?i)(y/n|yes/no|\[y\]|\[yes\])} {
        send "y\r"
        exp_continue
    }
    -re {\$ $} {
        # Prompt appeared — startup complete
    }
    timeout {
        # No prompt within 30s — assume startup succeeded
    }
}

# Hand off to the interactive session
interact
EXPECTEOF

    cat >> "$LAUNCHER" <<LAUNCHER_EOF
echo "[\$(date)] Starting manager bot..." >> $(printf '%q' "$LOG")
exec expect $(printf '%q' "$EXPECT_SCRIPT") 2>> $(printf '%q' "$LOG")
LAUNCHER_EOF
    chmod +x "$LAUNCHER"

    echo "Starting manager bot in tmux session: $SESSION_NAME"
    tmux new-session -d -s "$SESSION_NAME" -c "$CANTRIP_ROOT" "$LAUNCHER"

    # Wait briefly and check if the session survived
    sleep 2
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
    export DISCORD_CHANNEL_IDS="$ALL_CHANNEL_IDS"
    [ -n "$HUMAN_USER_ID" ] && export DISCORD_ALLOWED_USERS="$HUMAN_USER_ID"
    exec claude \
        --dangerously-load-development-channels server:cantrip-discord \
        --dangerously-skip-permissions \
        --append-system-prompt "$SYSTEM_PROMPT"
fi
