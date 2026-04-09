#!/usr/bin/env bash
#
# Cast a new project in Cantrip
# Creates: folder, CLAUDE.md, GitHub repo, Discord channel, bots.json entry
#
# Usage: ./create-project.sh <project-name> [options]
#
# Options:
#   --tech-stack <stack>       Tech stack (e.g., "Next.js", "Python FastAPI")
#   --deploy-target <target>   Deploy target (e.g., "Vercel", "Fly.io")
#   --deploy-command <cmd>     Deploy command (e.g., "vercel --prod --token \$VERCEL_TOKEN")
#   --category-id <id>         Discord category ID (overrides settings.json default)
#   --no-repo                  Skip GitHub repo creation
#   --no-channel               Skip Discord channel creation
#   --public                   Make GitHub repo public (default: private)
#
# Example:
#   ./create-project.sh my-landing-page --tech-stack "Next.js" --deploy-target "Vercel"

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- Parse arguments ---

if [ $# -lt 1 ]; then
    echo "Usage: $0 <project-name> [--tech-stack <stack>] [--deploy-target <target>] [--deploy-command <cmd>] [--category-id <id>] [--no-repo] [--no-channel] [--public]"
    echo ""
    echo "Example: $0 my-landing-page --tech-stack 'Next.js' --deploy-target 'Vercel'"
    exit 1
fi

PROJECT_NAME="$1"
shift

TECH_STACK=""
DEPLOY_TARGET=""
DEPLOY_COMMAND=""
CATEGORY_ID=$(cfg_category_id)
CREATE_REPO=true
CREATE_CHANNEL=true
REPO_VISIBILITY="--private"

while [ $# -gt 0 ]; do
    case "$1" in
        --tech-stack)     TECH_STACK="$2"; shift 2 ;;
        --deploy-target)  DEPLOY_TARGET="$2"; shift 2 ;;
        --deploy-command) DEPLOY_COMMAND="$2"; shift 2 ;;
        --category-id)    CATEGORY_ID="$2"; shift 2 ;;
        --no-repo)        CREATE_REPO=false; shift ;;
        --no-channel)     CREATE_CHANNEL=false; shift ;;
        --public)         REPO_VISIBILITY="--public"; shift ;;
        --private)        REPO_VISIBILITY="--private"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Validate project name ---

if [[ ! "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "ERROR: Invalid project name '$PROJECT_NAME'."
    echo "Use only lowercase letters, numbers, and hyphens (e.g., my-landing-page)."
    exit 1
fi

# --- Setup paths ---

PROJECT_DIR="$CANTRIP_ROOT/projects/$PROJECT_NAME"
TEMPLATE="$CANTRIP_ROOT/docs/templates/project-claude-md.md"
MANAGER_TOKEN=$(cfg_token "manager")
SERVER_ID=$(cfg_server_id)
HUMAN_USER_ID=$(cfg_human_user_id)

echo "=== Cantrip: Casting new project '$PROJECT_NAME' ==="
echo ""

# --- Preflight checks ---

if [ -d "$PROJECT_DIR" ]; then
    echo "ERROR: Project directory already exists: $PROJECT_DIR"
    exit 1
fi

if [ "$CREATE_REPO" = true ] && ! command -v gh &> /dev/null; then
    echo "ERROR: gh CLI is required for repo creation. Install with: brew install gh"
    exit 1
fi

if [ "$CREATE_CHANNEL" = true ]; then
    if [ -z "$MANAGER_TOKEN" ]; then
        echo "ERROR: No manager token in settings.json. Set tokens.manager."
        exit 1
    fi
    if [ -z "$SERVER_ID" ]; then
        echo "ERROR: No server_id in settings.json. Set discord.server_id."
        exit 1
    fi
fi

# --- Step 1: Create project directory ---

echo "1/5  Creating project directory..."
mkdir -p "$PROJECT_DIR/.memory"
echo "     $PROJECT_DIR"

# --- Step 2: Generate CLAUDE.md from template ---

echo "2/5  Writing CLAUDE.md from template..."
if [ -f "$TEMPLATE" ]; then
    sed \
        -e "s|{{PROJECT_NAME}}|$PROJECT_NAME|g" \
        -e "s|{{TECH_STACK}}|${TECH_STACK:-[TO BE CONFIGURED]}|g" \
        -e "s|{{DEPLOY_TARGET}}|${DEPLOY_TARGET:-[TO BE CONFIGURED]}|g" \
        -e "s|{{DEPLOY_COMMAND}}|${DEPLOY_COMMAND:-[TO BE CONFIGURED]}|g" \
        -e "s|{{REPO_URL}}|[TO BE CONFIGURED]|g" \
        -e "s|{{BUILD_COMMAND}}|[TO BE CONFIGURED]|g" \
        -e "s|{{TEST_COMMAND}}|[TO BE CONFIGURED]|g" \
        -e "s|{{PRODUCTION_URL}}|[TO BE CONFIGURED]|g" \
        "$TEMPLATE" > "$PROJECT_DIR/CLAUDE.md"
    echo "     CLAUDE.md written"
else
    echo "     WARNING: Template not found at $TEMPLATE. Skipping CLAUDE.md."
fi

# --- Step 3: Create GitHub repo ---

REPO_URL=""
if [ "$CREATE_REPO" = true ]; then
    echo "3/5  Creating GitHub repo..."
    cd "$PROJECT_DIR"
    git init -q
    echo "# $PROJECT_NAME" > README.md
    git add .
    git commit -q -m "Initial commit"

    if gh repo create "$PROJECT_NAME" $REPO_VISIBILITY --source=. --push 2>/dev/null; then
        REPO_URL=$(gh repo view --json url -q '.url' 2>/dev/null || echo "")
        echo "     Repo created: $REPO_URL"
    else
        echo "     WARNING: gh repo create failed. Repo may already exist or auth is needed."
        echo "     Run 'gh auth login' if not authenticated."
        REPO_URL=""
    fi

    # Update CLAUDE.md with repo URL if we got one
    if [ -n "$REPO_URL" ] && [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
        sed -i '' "s|\*\*Repository\*\*: \[TO BE CONFIGURED\]|**Repository**: $REPO_URL|" "$PROJECT_DIR/CLAUDE.md"
    fi

    cd "$CANTRIP_ROOT"
else
    echo "3/5  Skipping GitHub repo (--no-repo)"
fi

# --- Step 4: Create Discord channel ---

CHANNEL_ID=""
if [ "$CREATE_CHANNEL" = true ]; then
    echo "4/5  Creating Discord channel #$PROJECT_NAME..."

    # Build the JSON payload safely via jq
    if [ -n "$CATEGORY_ID" ]; then
        PAYLOAD=$(jq -n --arg name "$PROJECT_NAME" --arg parent "$CATEGORY_ID" \
            '{name: $name, type: 0, parent_id: $parent}')
    else
        PAYLOAD=$(jq -n --arg name "$PROJECT_NAME" '{name: $name, type: 0}')
    fi

    RESPONSE=$(curl -s -X POST "https://discord.com/api/v10/guilds/$SERVER_ID/channels" \
        -H "Authorization: Bot $MANAGER_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")

    CHANNEL_ID=$(echo "$RESPONSE" | jq -r '.id // empty')

    if [ -n "$CHANNEL_ID" ] && [ "$CHANNEL_ID" != "null" ]; then
        echo "     Channel created: #$PROJECT_NAME (ID: $CHANNEL_ID)"
    else
        ERROR_MSG=$(echo "$RESPONSE" | jq -r '.message // "Unknown error"')
        echo "     WARNING: Failed to create Discord channel: $ERROR_MSG"
        echo "     Create manually and add the channel ID to bots.json."
        CHANNEL_ID=""
    fi
else
    echo "4/5  Skipping Discord channel (--no-channel)"
fi

# --- Step 5: Update bots.json ---

echo "5/5  Updating bots.json..."
if [ -f "$BOTS_JSON" ]; then
    # Check if project already exists
    EXISTING=$(jq -r ".projects[\"$PROJECT_NAME\"] // empty" "$BOTS_JSON")
    if [ -n "$EXISTING" ]; then
        echo "     WARNING: Project '$PROJECT_NAME' already in bots.json. Updating..."
    fi

    bots_json_update ".projects[\"$PROJECT_NAME\"] = {
        \"discord_channel\": \"$PROJECT_NAME\",
        \"discord_channel_id\": $([ -n "$CHANNEL_ID" ] && echo "\"$CHANNEL_ID\"" || echo "null"),
        \"directory\": \"projects/$PROJECT_NAME\",
        \"deploy_target\": $([ -n "$DEPLOY_TARGET" ] && echo "\"$DEPLOY_TARGET\"" || echo "null"),
        \"deploy_command\": $([ -n "$DEPLOY_COMMAND" ] && echo "\"$DEPLOY_COMMAND\"" || echo "null"),
        \"tech_stack\": $([ -n "$TECH_STACK" ] && echo "\"$TECH_STACK\"" || echo "null"),
        \"repo_url\": $([ -n "$REPO_URL" ] && echo "\"$REPO_URL\"" || echo "null")
    }"

    echo "     bots.json updated"
else
    echo "     WARNING: bots.json not found at $BOTS_JSON"
fi

# --- Summary ---

echo ""
echo "=== Project '$PROJECT_NAME' cast successfully ==="
echo ""
echo "  Directory:  $PROJECT_DIR"
[ -n "$REPO_URL" ]    && echo "  Repository: $REPO_URL"
[ -n "$CHANNEL_ID" ]  && echo "  Channel:    #$PROJECT_NAME (ID: $CHANNEL_ID)"
[ -n "$TECH_STACK" ]  && echo "  Tech stack: $TECH_STACK"
[ -n "$DEPLOY_TARGET" ] && echo "  Deploy to:  $DEPLOY_TARGET"
echo ""
echo "Next: Attune a familiar to start work:"
echo "  ./config/scripts/start-worker.sh worker-N $PROJECT_NAME"
