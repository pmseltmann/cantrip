#!/usr/bin/env bash
#
# Start or re-attune a Worker Bot (Familiar) for Cantrip
# Usage: ./start-worker.sh <worker-id> <project-name>
#
# Example: ./start-worker.sh worker-1 project-1

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <worker-id> <project-name>"
    echo "Example: $0 worker-1 project-1"
    exit 1
fi

WORKER_ID="$1"
PROJECT_NAME="$2"
PROJECT_DIR="$CANTRIP_ROOT/projects/$PROJECT_NAME"
SESSION_NAME="cantrip-$WORKER_ID"

# Validate worker ID
if [[ ! "$WORKER_ID" =~ ^worker-[1-9][0-9]*$ ]]; then
    echo "ERROR: Invalid worker ID '$WORKER_ID'."
    exit 1
fi

# Validate project directory
if [ ! -d "$PROJECT_DIR" ]; then
    echo "ERROR: Project directory not found: $PROJECT_DIR"
    exit 1
fi

# Get token from config
TOKEN=$(require_token "$WORKER_ID")

# Look up the channel ID from bots.json
CHANNEL_ID=$(bots_project_channel_id "$PROJECT_NAME")

SYSTEM_PROMPT="You are a Worker Bot (${WORKER_ID}) assigned to the ${PROJECT_NAME} project. Read CLAUDE.md immediately for your full instructions.

CRITICAL RULE: You MUST only respond to messages in the #${PROJECT_NAME} channel${CHANNEL_ID:+ (ID: $CHANNEL_ID)}. If a message arrives from ANY other channel (#manager, other project channels, etc.), DO NOT RESPOND. Do not reply, do not acknowledge, do not send any message. Those channels are handled by other bots.

You have full read/write access to files in this project folder. Never access files outside this folder. Follow the git workflow and memory conventions in CLAUDE.md."

echo "=== Cantrip Familiar: $WORKER_ID → $PROJECT_NAME ==="
echo "Working directory: $PROJECT_DIR"
echo "Discord channel: #$PROJECT_NAME"
echo ""

if ! command -v claude &> /dev/null; then
    echo "ERROR: 'claude' command not found."
    exit 1
fi

# Kill existing session for this worker (if any)
if command -v tmux &> /dev/null && tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Killing existing session: $SESSION_NAME"
    tmux kill-session -t "$SESSION_NAME"
    sleep 1
fi

# Ensure .memory directory exists
mkdir -p "$PROJECT_DIR/.memory"

# Add the project's Discord channel to access.json if not already there
if [ -n "$CHANNEL_ID" ]; then
    if add_channel_to_access_json "$CHANNEL_ID"; then
        echo "Channel $CHANNEL_ID (#$PROJECT_NAME) registered in access.json."
    fi
elif [ -z "$CHANNEL_ID" ]; then
    echo "WARNING: No channel ID found for $PROJECT_NAME in bots.json. Worker may not receive messages."
    echo "Add the channel ID to bots.json and re-run, or manually update access.json."
fi

# Build environment variables for the worker session
REPLICATE_TOKEN=$(cfg_token "replicate" 2>/dev/null || echo "")
VERCEL_TOKEN_VAL=$(cfg_vercel_token 2>/dev/null || echo "")

# Write a launcher script to avoid shell quoting issues in tmux
LAUNCHER="/tmp/cantrip-${WORKER_ID}-launch.sh"
cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
LAUNCHER_EOF
echo "export DISCORD_BOT_TOKEN=$(printf '%q' "$TOKEN")" >> "$LAUNCHER"
[ -n "$REPLICATE_TOKEN" ] && echo "export REPLICATE_API_TOKEN=$(printf '%q' "$REPLICATE_TOKEN")" >> "$LAUNCHER"
[ -n "$VERCEL_TOKEN_VAL" ] && echo "export VERCEL_TOKEN=$(printf '%q' "$VERCEL_TOKEN_VAL")" >> "$LAUNCHER"
cat >> "$LAUNCHER" <<LAUNCHER_EOF
exec claude \\
    --channels plugin:discord@claude-plugins-official \\
    --dangerously-skip-permissions \\
    --append-system-prompt $(printf '%q' "$SYSTEM_PROMPT")
LAUNCHER_EOF
chmod +x "$LAUNCHER"

# Launch
if command -v tmux &> /dev/null; then
    echo "Starting $WORKER_ID in tmux session: $SESSION_NAME"
    tmux new-session -d -s "$SESSION_NAME" -c "$PROJECT_DIR" "$LAUNCHER"

    # Update bots.json with the new attunement
    bots_json_update ".workers[\"$WORKER_ID\"].assigned_project = \"$PROJECT_NAME\" | .workers[\"$WORKER_ID\"].assigned_channel = \"$PROJECT_NAME\" | .workers[\"$WORKER_ID\"].status = \"active\""

    echo "$WORKER_ID attuned. Attach: tmux attach -t $SESSION_NAME"
else
    echo "tmux not found — running in foreground."
    cd "$PROJECT_DIR"
    export DISCORD_BOT_TOKEN="$TOKEN"
    [ -n "$REPLICATE_TOKEN" ] && export REPLICATE_API_TOKEN="$REPLICATE_TOKEN"
    [ -n "$VERCEL_TOKEN_VAL" ] && export VERCEL_TOKEN="$VERCEL_TOKEN_VAL"
    exec claude \
        --channels plugin:discord@claude-plugins-official \
        --dangerously-skip-permissions \
        --append-system-prompt "$SYSTEM_PROMPT"
fi
