#!/usr/bin/env bash
#
# Cantrip Setup Wizard
# Interactive guided setup for the Cantrip multi-agent system.
# Walks through prerequisites, Discord config, token collection,
# config file generation, plugin install, and validation.
#
# Usage: ./setup.sh

set -uo pipefail
trap 'rm -f "${CANTRIP_CONFIG}.tmp" "${BOTS_JSON}.tmp"; echo -e "\n\nSetup interrupted. Re-run to continue."; exit 130' INT

# --- Paths (do NOT source lib.sh — config may not exist yet) ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANTRIP_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CANTRIP_CONFIG="$CANTRIP_ROOT/config/settings.json"
BOTS_JSON="$CANTRIP_ROOT/config/bots.json"

# --- Colors (respect NO_COLOR convention) ---

if [[ -n "${NO_COLOR:-}" ]] || [[ "${TERM:-}" == "dumb" ]]; then
    BOLD=''; GREEN=''; RED=''; YELLOW=''; CYAN=''; RESET=''
else
    BOLD='\033[1m'
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    RESET='\033[0m'
fi

header()  { echo -e "\n${BOLD}${CYAN}=== $1 ===${RESET}\n"; }
success() { echo -e "  ${GREEN}✓${RESET} $1"; }
error()   { echo -e "  ${RED}✗${RESET} $1"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET} $1"; }
info()    { echo -e "  $1"; }

prompt_enter() {
    echo ""
    read -rp "  Press Enter when ready... "
}

trim() {
    # Trim leading/trailing whitespace — critical for copy-pasted tokens and IDs
    local val="$1"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    echo "$val"
}

prompt_value() {
    # prompt_value "Label" — returns trimmed value via stdout
    local label="$1"
    local value
    read -rp "  $label: " value
    trim "$value"
}

prompt_secret() {
    # prompt_secret "Label" — reads without echo, returns trimmed value via stdout
    local label="$1"
    local value
    read -rsp "  $label: " value
    echo "" >&2  # newline after hidden input (must go to stderr, not stdout)
    trim "$value"
}

prompt_yesno() {
    # prompt_yesno "Question" — returns 0 for yes, 1 for no
    local question="$1"
    local answer
    read -rp "  $question [Y/n]: " answer
    [[ -z "$answer" || "$answer" =~ ^[Yy] ]]
}

validate_discord_id() {
    [[ "$1" =~ ^[0-9]{17,20}$ ]]
}

validate_bot_token() {
    # Quick check: hit Discord API to verify the token is valid.
    # Returns 0 if valid, 1 if not. Also sets BOT_USER_ID_FROM_API if valid.
    local token="$1"
    local response
    response=$(curl -s -w "\n%{http_code}" -H "Authorization: Bot $token" "https://discord.com/api/v10/users/@me" 2>/dev/null || echo "000")
    local http_code
    http_code=$(echo "$response" | tail -1)
    if [ "$http_code" = "200" ]; then
        BOT_USER_ID_FROM_API=$(echo "$response" | head -1 | jq -r '.id // empty' 2>/dev/null || echo "")
        return 0
    fi
    return 1
}

# ============================================================
header "Welcome to Cantrip Setup"
# ============================================================

echo -e "  This wizard will set up Cantrip — a system that lets you"
echo -e "  build, test, and deploy software by chatting in Discord."
echo -e "  You'll have a team of AI coding agents, coordinated by a manager bot."
echo -e ""
echo -e "  ${BOLD}What you'll need:${RESET}"
echo -e "    - A Discord account (free)"
echo -e "    - A Claude Max plan (~\$100/mo)"
echo -e "    - A GitHub account (free)"
echo -e "    - About 30-45 minutes"
echo -e ""
echo -e "  ${BOLD}When you're done:${RESET}"
echo -e "    - A running manager bot connected to your Discord server"
echo -e "    - A pool of worker bots ready to be assigned to projects"
echo -e "    - One command to start building: 'create a new project called my-app'"
echo -e ""
echo -e "  The wizard handles config files and validation."
echo -e "  Some steps require your browser (Discord Developer Portal)."

prompt_enter

# ============================================================
header "Step 1: Prerequisites"
# ============================================================

MISSING=0
for cmd in tmux jq bun gh claude node; do
    if command -v "$cmd" &>/dev/null; then
        version=$("$cmd" --version 2>/dev/null | head -1 || echo "installed")
        success "$cmd ($version)"
    else
        case "$cmd" in
            tmux)  error "$cmd — install with: brew install tmux" ;;
            jq)    error "$cmd — install with: brew install jq" ;;
            bun)   error "$cmd — install with: brew install oven-sh/bun/bun" ;;
            gh)    error "$cmd — install with: brew install gh" ;;
            claude) error "$cmd — install with: npm install -g @anthropic-ai/claude-code" ;;
            node)  error "$cmd — install with: brew install node" ;;
        esac
        MISSING=$((MISSING + 1))
    fi
done

if [ "$MISSING" -gt 0 ]; then
    echo ""
    warn "$MISSING tool(s) missing. Install them and re-run this wizard."
    if ! prompt_yesno "Continue anyway?"; then
        exit 1
    fi
fi

# Check gh auth
if command -v gh &>/dev/null; then
    if gh auth status &>/dev/null; then
        success "gh CLI — authenticated"
    else
        warn "gh CLI — not authenticated. Run 'gh auth login' before creating projects."
    fi
fi

# ============================================================
header "Step 2: Discord Server"
# ============================================================

echo -e "  Create a Discord server if you haven't already:"
echo -e ""
echo -e "  1. Open Discord → click '+' → 'Create My Own' → 'For me and my friends'"
echo -e "  2. Name it 'Cantrip Workspace' (or your preference)"
echo -e "  3. Create a ${BOLD}#manager${RESET} channel in a 'System' category"
echo -e "     (Project channels are created automatically by the manager bot later)"
echo -e "     Optionally create a 'Projects' category — project channels go there"
echo -e "  4. Enable Developer Mode: Settings → Advanced → Developer Mode"
echo -e ""
echo -e "  ${YELLOW}Tip:${RESET} Right-click any server/channel/user → 'Copy ID' to get Discord IDs."

prompt_enter

# How many workers? (ask before Step 3 so instructions are accurate)
NUM_WORKERS=""
while [[ ! "$NUM_WORKERS" =~ ^[1-9][0-9]*$ ]]; do
    NUM_WORKERS=$(prompt_value "How many worker bots do you want? (e.g., 2)")
    [[ ! "$NUM_WORKERS" =~ ^[1-9][0-9]*$ ]] && warn "Enter a positive number (1, 2, 3, ...)"
done
TOTAL_BOTS=$((NUM_WORKERS + 1))

# ============================================================
header "Step 3: Discord Bot Applications"
# ============================================================

echo -e "  Go to ${BOLD}https://discord.com/developers/applications${RESET}"
if prompt_yesno "Open the Developer Portal in your browser?"; then
    open "https://discord.com/developers/applications" 2>/dev/null || true
fi
echo -e ""
echo -e "  Create ${BOLD}$TOTAL_BOTS bot applications${RESET} (1 manager + $NUM_WORKERS worker(s))."
echo -e "  For each one:"
echo -e "    1. Click 'New Application', name it (e.g., Cantrip-Manager, Cantrip-Worker-1)"
echo -e "    2. ${BOLD}Bot tab${RESET} (left sidebar) → click 'Reset Token' → 'Yes, do it!'"
echo -e "       Copy the token immediately — you can't see it again"
echo -e "    3. ${BOLD}Bot tab${RESET} → scroll down to 'Privileged Gateway Intents'"
echo -e "       Toggle ON ${BOLD}'Message Content Intent'${RESET} → click Save Changes"
echo -e "       (This lets the bot read message text — without it, bots connect but can't see what you type)"
echo -e "    4. ${BOLD}OAuth2 tab${RESET} (left sidebar) → URL Generator"
echo -e "       Check 'bot' under Scopes (a permissions panel appears below)"
echo -e "       Select: View Channels, Send Messages, Read Message History,"
echo -e "       Attach Files, Add Reactions"
echo -e "       (Manager also needs: Manage Channels, Manage Roles)"
echo -e "    5. Copy the generated URL at the bottom → paste in browser → invite to your server"
echo -e ""
echo -e "  ${YELLOW}Note:${RESET} Discord roles are optional for initial setup."
echo -e "  You can add them later for channel isolation. See config/discord-setup.md Step 3."

prompt_enter

# ============================================================
header "Step 4: Collect Tokens and IDs"
# ============================================================

echo -e "  Now let's collect all the tokens and IDs."
echo -e "  Tokens are entered securely (not displayed)."
echo -e ""
echo -e "  ${YELLOW}Prerequisite:${RESET} Make sure Developer Mode is on in Discord:"
echo -e "  Settings → Advanced → Developer Mode"
echo -e "  Then right-click any server/channel/user → 'Copy ID'"
echo ""
info "${BOLD}Discord IDs${RESET}"

SERVER_ID=""
while ! validate_discord_id "$SERVER_ID"; do
    SERVER_ID=$(prompt_value "Server ID (right-click server name → Copy ID)")
    validate_discord_id "$SERVER_ID" || warn "Should be a 17-20 digit number"
done

MANAGER_CHANNEL_ID=""
while ! validate_discord_id "$MANAGER_CHANNEL_ID"; do
    MANAGER_CHANNEL_ID=$(prompt_value "#manager channel ID")
    validate_discord_id "$MANAGER_CHANNEL_ID" || warn "Should be a 17-20 digit number"
done

USER_ID=""
while ! validate_discord_id "$USER_ID"; do
    USER_ID=$(prompt_value "Your Discord user ID (right-click your name → Copy ID)")
    validate_discord_id "$USER_ID" || warn "Should be a 17-20 digit number"
done

PROJECTS_CATEGORY_ID=$(prompt_value "Projects category ID (right-click 'Projects' category → Copy ID, or Enter to skip)")
[ -n "$PROJECTS_CATEGORY_ID" ] && { validate_discord_id "$PROJECTS_CATEGORY_ID" || warn "Doesn't look like a valid Discord ID"; }

GITHUB_USERNAME=$(prompt_value "GitHub username (for repo creation, or Enter to skip)")
[ -z "$GITHUB_USERNAME" ] && warn "Skipped — you'll need this for 'gh repo create'"

echo ""
info "${BOLD}Manager Bot${RESET}"

MANAGER_TOKEN=""
while [ -z "$MANAGER_TOKEN" ]; do
    MANAGER_TOKEN=$(prompt_secret "Manager bot token (paste from Developer Portal)")
    [ -z "$MANAGER_TOKEN" ] && warn "Token cannot be empty"
done

# Validate token via Discord API
BOT_USER_ID_FROM_API=""
if validate_bot_token "$MANAGER_TOKEN"; then
    success "Manager token is valid"
    if [ -n "$BOT_USER_ID_FROM_API" ]; then
        info "  Auto-detected bot user ID: $BOT_USER_ID_FROM_API"
        MANAGER_BOT_USER_ID="$BOT_USER_ID_FROM_API"
    fi
else
    warn "Could not verify manager token via Discord API. It may still be correct."
fi

if [ -z "$MANAGER_BOT_USER_ID" ]; then
    while ! validate_discord_id "$MANAGER_BOT_USER_ID"; do
        MANAGER_BOT_USER_ID=$(prompt_value "Manager bot user ID (right-click bot in server → Copy ID)")
        validate_discord_id "$MANAGER_BOT_USER_ID" || warn "Should be a 17-20 digit number"
    done
fi

# Collect worker tokens and IDs
declare -a WORKER_TOKENS
declare -a WORKER_BOT_USER_IDS

for i in $(seq 1 "$NUM_WORKERS"); do
    echo ""
    info "${BOLD}Worker-$i Bot${RESET}"

    token=""
    while [ -z "$token" ]; do
        token=$(prompt_secret "Worker-$i bot token")
        [ -z "$token" ] && warn "Token cannot be empty"
    done
    WORKER_TOKENS+=("$token")

    # Validate token and auto-detect bot user ID
    BOT_USER_ID_FROM_API=""
    bot_user_id=""
    if validate_bot_token "$token"; then
        success "Worker-$i token is valid"
        if [ -n "$BOT_USER_ID_FROM_API" ]; then
            info "  Auto-detected bot user ID: $BOT_USER_ID_FROM_API"
            bot_user_id="$BOT_USER_ID_FROM_API"
        fi
    else
        warn "Could not verify Worker-$i token via Discord API."
    fi

    if [ -z "$bot_user_id" ]; then
        while ! validate_discord_id "$bot_user_id"; do
            bot_user_id=$(prompt_value "Worker-$i bot user ID")
            validate_discord_id "$bot_user_id" || warn "Should be a 17-20 digit number"
        done
    fi
    WORKER_BOT_USER_IDS+=("$bot_user_id")
done

echo ""
info "${BOLD}Optional Tokens${RESET} (press Enter to skip)"

VERCEL_TOKEN=$(prompt_secret "Vercel token (optional, for deploys)")
REPLICATE_TOKEN=$(prompt_secret "Replicate API token (optional, for image gen)")

# --- Cross-check IDs ---

if [ "$SERVER_ID" = "$MANAGER_CHANNEL_ID" ] || [ "$SERVER_ID" = "$USER_ID" ] || [ "$MANAGER_CHANNEL_ID" = "$USER_ID" ]; then
    echo ""
    warn "Some IDs look identical — server ID, channel ID, and user ID should all be different."
    if ! prompt_yesno "Continue anyway?"; then
        error "Setup cancelled. Re-run the wizard to fix the IDs."
        exit 1
    fi
fi

# ============================================================
header "Review Your Configuration"
# ============================================================

echo -e "  ${BOLD}Server ID${RESET}:          $SERVER_ID"
echo -e "  ${BOLD}Manager Channel ID${RESET}: $MANAGER_CHANNEL_ID"
echo -e "  ${BOLD}Category ID${RESET}:        ${PROJECTS_CATEGORY_ID:-(skipped)}"
echo -e "  ${BOLD}Your User ID${RESET}:       $USER_ID"
echo -e "  ${BOLD}GitHub Username${RESET}:    ${GITHUB_USERNAME:-(skipped)}"
echo -e "  ${BOLD}Manager Bot ID${RESET}:     $MANAGER_BOT_USER_ID"
for i in $(seq 1 "$NUM_WORKERS"); do
    idx=$((i - 1))
    echo -e "  ${BOLD}Worker-$i Bot ID${RESET}:    ${WORKER_BOT_USER_IDS[$idx]}"
done
echo -e "  ${BOLD}Tokens${RESET}:             (hidden) manager + $NUM_WORKERS worker(s)"
[ -n "$VERCEL_TOKEN" ] && echo -e "  ${BOLD}Vercel token${RESET}:      (set)"
[ -n "$REPLICATE_TOKEN" ] && echo -e "  ${BOLD}Replicate token${RESET}:   (set)"
echo ""

if ! prompt_yesno "Does this look correct?"; then
    error "Setup cancelled. Re-run the wizard to start over."
    exit 1
fi

# ============================================================
header "Step 5: Generate Config Files"
# ============================================================

# Build settings.json
WRITE_SETTINGS=false
if [ -f "$CANTRIP_CONFIG" ]; then
    warn "settings.json already exists."
    if ! prompt_yesno "Overwrite?"; then
        info "Skipping settings.json"
    else
        WRITE_SETTINGS=true
    fi
else
    WRITE_SETTINGS=true
fi

if [ "$WRITE_SETTINGS" = true ]; then
    # Start with base structure
    SETTINGS=$(jq -n \
        --arg server_id "$SERVER_ID" \
        --arg manager_channel_id "$MANAGER_CHANNEL_ID" \
        --arg category_id "$PROJECTS_CATEGORY_ID" \
        --arg user_id "$USER_ID" \
        --arg github_username "$GITHUB_USERNAME" \
        --arg manager_token "$MANAGER_TOKEN" \
        --arg manager_bot_uid "$MANAGER_BOT_USER_ID" \
        '{
            discord: {
                server_id: $server_id,
                manager_channel_id: $manager_channel_id,
                projects_category_id: (if $category_id == "" then null else $category_id end)
            },
            user: {
                discord_user_id: $user_id,
                github_username: $github_username
            },
            tokens: {
                manager: $manager_token,
                vercel: null,
                replicate: null
            },
            bots: {
                manager: {
                    discord_user_id: $manager_bot_uid,
                    discord_role_id: null
                }
            }
        }')

    # Add optional tokens
    [ -n "$VERCEL_TOKEN" ] && SETTINGS=$(printf '%s\n' "$SETTINGS" | jq --arg t "$VERCEL_TOKEN" '.tokens.vercel = $t')
    [ -n "$REPLICATE_TOKEN" ] && SETTINGS=$(printf '%s\n' "$SETTINGS" | jq --arg t "$REPLICATE_TOKEN" '.tokens.replicate = $t')

    # Add worker entries
    for i in $(seq 1 "$NUM_WORKERS"); do
        idx=$((i - 1))
        SETTINGS=$(printf '%s\n' "$SETTINGS" | jq \
            --arg name "worker-$i" \
            --arg token "${WORKER_TOKENS[$idx]}" \
            --arg uid "${WORKER_BOT_USER_IDS[$idx]}" \
            '.tokens[$name] = $token | .bots[$name] = {discord_user_id: $uid, discord_role_id: null}')
    done

    # Validate and write atomically
    if printf '%s\n' "$SETTINGS" | jq empty 2>/dev/null; then
        printf '%s\n' "$SETTINGS" | jq '.' > "${CANTRIP_CONFIG}.tmp" && mv "${CANTRIP_CONFIG}.tmp" "$CANTRIP_CONFIG"
        success "settings.json written to $CANTRIP_CONFIG"
    else
        error "Failed to generate valid settings.json. This is a bug — please report it."
        rm -f "${CANTRIP_CONFIG}.tmp"
        exit 1
    fi
fi

# Build bots.json
WRITE_BOTS=false
if [ -f "$BOTS_JSON" ]; then
    warn "bots.json already exists."
    # Check for active workers that would lose their attunement
    active_workers=$(jq -r '[.workers | to_entries[] | select(.value.status == "active" or .value.assigned_project != null)] | length' "$BOTS_JSON" 2>/dev/null || echo "0")
    if [ "$active_workers" -gt 0 ]; then
        warn "$active_workers worker(s) currently have active attunements. Overwriting will reset them."
    fi
    if ! prompt_yesno "Overwrite?"; then
        info "Skipping bots.json"
    else
        WRITE_BOTS=true
    fi
else
    WRITE_BOTS=true
fi

if [ "$WRITE_BOTS" = true ]; then
    BOTS='{"$comment": "Cantrip runtime state. Updated by scripts — generally do not edit manually.", "workers": {}, "projects": {}}'

    for i in $(seq 1 "$NUM_WORKERS"); do
        BOTS=$(printf '%s\n' "$BOTS" | jq --arg name "worker-$i" \
            '.workers[$name] = {assigned_project: null, assigned_channel: null, status: "idle"}')
    done

    printf '%s\n' "$BOTS" | jq '.' > "${BOTS_JSON}.tmp" && mv "${BOTS_JSON}.tmp" "$BOTS_JSON"
    success "bots.json written"
fi

# Ensure projects directory exists
if [ ! -d "$CANTRIP_ROOT/projects" ]; then
    mkdir -p "$CANTRIP_ROOT/projects"
    success "Created projects/ directory"
else
    success "projects/ directory already exists"
fi

# ============================================================
header "Step 6: Discord Plugin"
# ============================================================

PLUGIN_FOUND=false
if [ -d "$HOME/.claude/plugins" ]; then
    for dir in "$HOME/.claude/plugins/"*discord* "$HOME/.claude/plugins/"*Discord*; do
        if [ -d "$dir" ] 2>/dev/null; then
            PLUGIN_FOUND=true
            break
        fi
    done
fi

if [ "$PLUGIN_FOUND" = true ]; then
    success "Discord plugin already installed"
else
    warn "Discord plugin not detected."
    echo ""
    info "Install it by running this in any Claude Code session:"
    echo -e "    ${BOLD}/plugin install discord@claude-plugins-official${RESET}"
    prompt_enter
fi

# ============================================================
header "Step 7: Bot Pairing"
# ============================================================

echo -e "  Each bot needs a one-time pairing with your Discord account."
echo -e "  This is the most hands-on step — about 2 minutes per bot."
echo -e "  You'll pair ${BOLD}$TOTAL_BOTS bot(s)${RESET}."
echo -e ""
echo -e "  For each bot, we launch a Claude Code session with its token pre-set."
echo -e "  Inside the session, run:"
echo -e ""
echo -e "    ${BOLD}/discord:configure${RESET}  → paste the same bot token when prompted"
echo -e ""
echo -e "    Then in Discord: click the bot's name in the member list → Message"
echo -e "    Type anything (e.g., 'hello') — the bot replies with a 6-digit pairing code"
echo -e ""
echo -e "    ${BOLD}/discord:access pair <code>${RESET}  → enter the code from the DM"
echo -e "    ${BOLD}/discord:access policy allowlist${RESET}"
echo -e "    ${BOLD}/exit${RESET}"
echo -e ""
echo -e "  ${YELLOW}Note:${RESET} 'access policy allowlist' restricts bots to only respond to paired users."
echo -e "  This setting is shared — set it once on the first bot, subsequent bots inherit it."

ALL_BOTS=("manager")
for i in $(seq 1 "$NUM_WORKERS"); do
    ALL_BOTS+=("worker-$i")
done

PAIR_INDEX=0
for bot_name in "${ALL_BOTS[@]}"; do
    PAIR_INDEX=$((PAIR_INDEX + 1))
    echo ""
    info "${BOLD}Bot $PAIR_INDEX of $TOTAL_BOTS${RESET}"
    if prompt_yesno "Launch pairing session for $bot_name?"; then
        if [ "$bot_name" = "manager" ]; then
            bot_token="$MANAGER_TOKEN"
        else
            idx=$(echo "$bot_name" | sed 's/worker-//')
            idx=$((idx - 1))
            bot_token="${WORKER_TOKENS[$idx]}"
        fi
        echo ""
        info "Launching Claude Code for $bot_name..."
        info "Run the pairing commands above, then /exit when done."
        echo ""
        if DISCORD_BOT_TOKEN="$bot_token" claude --channels plugin:discord@claude-plugins-official; then
            success "$bot_name pairing session completed"
        else
            warn "$bot_name session exited with an error. You can re-pair later manually."
        fi
    else
        info "Skipping $bot_name — pair it later manually"
    fi
done

# ============================================================
header "Step 8: Validation"
# ============================================================

echo -e "  Running preflight checks..."
echo ""
"$SCRIPT_DIR/validate.sh" || true

# ============================================================
header "Setup Complete!"
# ============================================================

echo -e "  ${GREEN}${BOLD}Cantrip is ready.${RESET}"
echo -e ""
echo -e "  Your system: 1 manager bot + $NUM_WORKERS worker bot(s)"
echo -e ""
echo -e "  ${BOLD}To start:${RESET}"
echo -e "    ${BOLD}./config/scripts/start-all.sh${RESET}"
echo -e ""
echo -e "  ${BOLD}To verify it's working:${RESET}"
echo -e "    1. Run start-all.sh above"
echo -e "    2. Go to your Discord server"
echo -e "    3. Post in #manager: ${BOLD}hello${RESET}"
echo -e "    4. The manager bot should respond within 10-15 seconds"
echo -e ""
echo -e "  ${BOLD}To build something:${RESET}"
echo -e "    Post in #manager: ${BOLD}create a new project called my-app${RESET}"
echo -e ""
echo -e "  For troubleshooting: ${BOLD}./config/scripts/health.sh${RESET}"
echo -e "  For architecture:    ${BOLD}docs/ARCHITECTURE.md${RESET}"
echo -e ""
