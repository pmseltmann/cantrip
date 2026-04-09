#!/usr/bin/env bash
#
# Cantrip Setup Wizard
# Interactive guided setup for the Cantrip multi-agent system.
# Walks through prerequisites, Discord config, token collection,
# config file generation, plugin install, and validation.
#
# Usage: ./setup.sh [--add-worker]

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
    # Shows character count after entry so user knows something was captured
    local label="$1"
    local value
    read -rsp "  $label: " value
    local len=${#value}
    if [ "$len" -gt 0 ]; then
        echo -e " ${GREEN}(${len} chars)${RESET}" >&2
    else
        echo "" >&2
    fi
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

# --- Argument parsing ---

ADD_WORKER_MODE=false
FRESH_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --add-worker)
            ADD_WORKER_MODE=true
            shift
            ;;
        --fresh)
            FRESH_MODE=true
            shift
            ;;
        -h|--help)
            echo "Usage: setup.sh [--add-worker] [--fresh]"
            echo ""
            echo "  --add-worker   Add a new worker bot to an existing configuration"
            echo "  --fresh        Start from scratch (ignore existing config)"
            echo "  (no flags)     Resume where you left off, or start fresh if no config"
            exit 0
            ;;
        *)
            echo "Unknown option: $1 (try --help)"
            exit 1
            ;;
    esac
done

# ============================================================
# --add-worker mode: add a single worker to existing config
# ============================================================

if [ "$ADD_WORKER_MODE" = true ]; then
    header "Add Worker Bot"

    if [ ! -f "$CANTRIP_CONFIG" ] || ! jq empty "$CANTRIP_CONFIG" 2>/dev/null; then
        error "settings.json not found or invalid. Run setup.sh first (without --add-worker)."
        exit 1
    fi
    if [ ! -f "$BOTS_JSON" ] || ! jq empty "$BOTS_JSON" 2>/dev/null; then
        error "bots.json not found or invalid. Run setup.sh first (without --add-worker)."
        exit 1
    fi

    # Determine next worker number
    existing_workers=$(jq -r '[.tokens | keys[] | select(startswith("worker-"))] | length' "$CANTRIP_CONFIG" 2>/dev/null || echo "0")
    NEXT_NUM=$((existing_workers + 1))
    WORKER_NAME="worker-$NEXT_NUM"

    info "Adding ${BOLD}$WORKER_NAME${RESET} (you have $existing_workers worker(s) currently)."
    echo ""

    # Collect token
    token=""
    while [ -z "$token" ]; do
        token=$(prompt_secret "$WORKER_NAME bot token")
        [ -z "$token" ] && warn "Token cannot be empty"
    done

    # Validate and auto-detect bot user ID
    BOT_USER_ID_FROM_API=""
    bot_user_id=""
    if validate_bot_token "$token"; then
        success "$WORKER_NAME token is valid"
        if [ -n "$BOT_USER_ID_FROM_API" ]; then
            info "  Auto-detected bot user ID: $BOT_USER_ID_FROM_API"
            bot_user_id="$BOT_USER_ID_FROM_API"
        fi
    else
        warn "Could not verify token via Discord API."
    fi

    if [ -z "$bot_user_id" ]; then
        while ! validate_discord_id "$bot_user_id"; do
            bot_user_id=$(prompt_value "$WORKER_NAME bot user ID")
            validate_discord_id "$bot_user_id" || warn "Should be a 17-20 digit number"
        done
    fi

    # Update settings.json
    UPDATED_SETTINGS=$(jq \
        --arg name "$WORKER_NAME" \
        --arg token "$token" \
        --arg uid "$bot_user_id" \
        '.tokens[$name] = $token | .bots[$name] = {discord_user_id: $uid, discord_role_id: null}' \
        "$CANTRIP_CONFIG")

    if printf '%s\n' "$UPDATED_SETTINGS" | jq empty 2>/dev/null; then
        printf '%s\n' "$UPDATED_SETTINGS" | jq '.' > "${CANTRIP_CONFIG}.tmp" && mv "${CANTRIP_CONFIG}.tmp" "$CANTRIP_CONFIG"
        success "settings.json updated with $WORKER_NAME"
    else
        error "Failed to update settings.json. This is a bug — please report it."
        rm -f "${CANTRIP_CONFIG}.tmp"
        exit 1
    fi

    # Update bots.json
    UPDATED_BOTS=$(jq \
        --arg name "$WORKER_NAME" \
        '.workers[$name] = {assigned_project: null, assigned_channel: null, status: "idle"}' \
        "$BOTS_JSON")

    printf '%s\n' "$UPDATED_BOTS" | jq '.' > "${BOTS_JSON}.tmp" && mv "${BOTS_JSON}.tmp" "$BOTS_JSON"
    success "bots.json updated with $WORKER_NAME"

    # Offer pairing
    echo ""
    if prompt_yesno "Launch pairing session for $WORKER_NAME now?"; then
        info "Launching Claude Code for $WORKER_NAME..."
        info "Run: /discord:configure, then pair via DM, then /exit"
        echo ""
        if DISCORD_BOT_TOKEN="$token" claude --channels plugin:discord@claude-plugins-official; then
            success "$WORKER_NAME pairing completed"
        else
            warn "$WORKER_NAME session exited with an error. You can re-pair later."
        fi
    fi

    echo ""
    success "${BOLD}$WORKER_NAME added.${RESET} Start it with: ./config/scripts/start-worker.sh $WORKER_NAME <project-name>"
    exit 0
fi

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
# Load existing config values (for per-field resume)
# ============================================================

# Helper: read a value from existing settings.json (empty string if missing)
existing_cfg() {
    if [ -f "$CANTRIP_CONFIG" ] && [ "$FRESH_MODE" = false ]; then
        jq -r "$1 // empty" "$CANTRIP_CONFIG" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

RESUME_MODE=false

if [ -f "$CANTRIP_CONFIG" ] && jq empty "$CANTRIP_CONFIG" 2>/dev/null && [ "$FRESH_MODE" = false ]; then
    echo ""
    info "Existing ${BOLD}settings.json${RESET} detected — will skip already-configured values."
    info "Run with ${BOLD}--fresh${RESET} to start from scratch."

    existing_workers=$(jq -r '[.tokens | keys[] | select(startswith("worker-"))] | length' "$CANTRIP_CONFIG" 2>/dev/null || echo "0")
    existing_server=$(jq -r '.discord.server_id // "(not set)"' "$CANTRIP_CONFIG" 2>/dev/null)
    existing_manager_token=$(jq -r '.tokens.manager // empty' "$CANTRIP_CONFIG" 2>/dev/null)
    info "  Server ID: $existing_server"
    info "  Workers configured: $existing_workers"
    info "  Manager token: ${existing_manager_token:+(set)}"

    # If ALL values are filled (server, manager channel, user, manager token, ≥1 worker), offer full skip
    existing_mgr_channel=$(existing_cfg '.discord.manager_channel_id')
    existing_user=$(existing_cfg '.user.discord_user_id')
    if [ -n "$existing_server" ] && [ "$existing_server" != "(not set)" ] && \
       [ -n "$existing_mgr_channel" ] && [ -n "$existing_user" ] && \
       [ -n "$existing_manager_token" ] && [ "$existing_workers" -gt 0 ]; then
        echo ""
        if prompt_yesno "Config looks complete. Skip to pairing & validation?"; then
            RESUME_MODE=true

            NUM_WORKERS="$existing_workers"
            TOTAL_BOTS=$((NUM_WORKERS + 1))
            MANAGER_TOKEN="$existing_manager_token"
            SERVER_ID="$existing_server"
            MANAGER_CHANNEL_ID="$existing_mgr_channel"
            USER_ID="$existing_user"

            declare -a WORKER_TOKENS
            declare -a WORKER_BOT_USER_IDS
            for i in $(seq 1 "$NUM_WORKERS"); do
                WORKER_TOKENS+=("$(jq -r ".tokens[\"worker-$i\"] // empty" "$CANTRIP_CONFIG" 2>/dev/null)")
                WORKER_BOT_USER_IDS+=("$(jq -r ".bots[\"worker-$i\"].discord_user_id // empty" "$CANTRIP_CONFIG" 2>/dev/null)")
            done

            info "Skipping to plugin check and pairing..."
        fi
    fi
    echo ""
fi

if [ "$RESUME_MODE" = false ]; then
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
echo -e "  ${GREEN}Values from existing config will be kept — press Enter to accept.${RESET}"
echo -e ""
echo -e "  ${YELLOW}Prerequisite:${RESET} Make sure Developer Mode is on in Discord:"
echo -e "  Settings → Advanced → Developer Mode"
echo -e "  Then right-click any server/channel/user → 'Copy ID'"

# Helper: prompt for a Discord ID, showing existing value if present
# Usage: result=$(prompt_or_keep_id "Label" "$existing_value")
prompt_or_keep_id() {
    local label="$1"
    local existing="$2"
    local value

    if [ -n "$existing" ] && validate_discord_id "$existing"; then
        echo ""
        read -rp "  $label [$existing]: " value
        value=$(trim "$value")
        if [ -z "$value" ]; then
            echo "$existing"
            return
        fi
    else
        value=""
    fi

    while ! validate_discord_id "$value"; do
        [ -n "$value" ] && warn "Should be a 17-20 digit number" >&2
        read -rp "  $label: " value
        value=$(trim "$value")
    done
    echo "$value"
}

# Helper: prompt for a token with retry on validation failure
# Usage: collect_bot_token "Label" "$existing_token"
# Sets: COLLECTED_TOKEN, COLLECTED_BOT_USER_ID
collect_bot_token() {
    local label="$1"
    local existing="$2"
    COLLECTED_TOKEN=""
    COLLECTED_BOT_USER_ID=""

    # If we have an existing token, try validating it first
    if [ -n "$existing" ]; then
        info "  Validating existing $label token..."
        BOT_USER_ID_FROM_API=""
        if validate_bot_token "$existing"; then
            success "$label token is valid"
            COLLECTED_TOKEN="$existing"
            COLLECTED_BOT_USER_ID="${BOT_USER_ID_FROM_API:-}"
            return
        else
            warn "Existing $label token failed validation — may be expired or revoked."
        fi
    fi

    # Token entry with retry loop
    while true; do
        local token=""
        while [ -z "$token" ]; do
            token=$(prompt_secret "$label bot token (paste from Developer Portal)")
            [ -z "$token" ] && warn "Token cannot be empty"
        done

        BOT_USER_ID_FROM_API=""
        if validate_bot_token "$token"; then
            success "$label token is valid"
            COLLECTED_TOKEN="$token"
            COLLECTED_BOT_USER_ID="${BOT_USER_ID_FROM_API:-}"
            return
        else
            warn "Token rejected by Discord API (invalid, expired, or network issue)."
            echo ""
            echo -e "  ${BOLD}Options:${RESET}"
            echo -e "    1. Try again with a different token"
            echo -e "    2. Keep this token anyway (skip validation)"
            echo -e "    3. Abort setup"
            local choice=""
            read -rp "  Enter 1, 2, or 3 [1]: " choice
            choice="${choice:-1}"
            case "$choice" in
                2)
                    COLLECTED_TOKEN="$token"
                    return
                    ;;
                3)
                    error "Setup aborted."
                    exit 1
                    ;;
                *)
                    # Loop back to try again
                    ;;
            esac
        fi
    done
}

echo ""
info "${BOLD}Discord IDs${RESET}"

SERVER_ID=$(prompt_or_keep_id "Server ID (right-click server name → Copy ID)" "$(existing_cfg '.discord.server_id')")

MANAGER_CHANNEL_ID=$(prompt_or_keep_id "#manager channel ID" "$(existing_cfg '.discord.manager_channel_id')")

USER_ID=$(prompt_or_keep_id "Your Discord user ID (right-click your name → Copy ID)" "$(existing_cfg '.user.discord_user_id')")

existing_category=$(existing_cfg '.discord.projects_category_id')
if [ -n "$existing_category" ]; then
    echo ""
    read -rp "  Projects category ID [$existing_category]: " PROJECTS_CATEGORY_ID
    PROJECTS_CATEGORY_ID=$(trim "$PROJECTS_CATEGORY_ID")
    [ -z "$PROJECTS_CATEGORY_ID" ] && PROJECTS_CATEGORY_ID="$existing_category"
else
    PROJECTS_CATEGORY_ID=$(prompt_value "Projects category ID (right-click 'Projects' category → Copy ID, or Enter to skip)")
fi
[ -n "$PROJECTS_CATEGORY_ID" ] && { validate_discord_id "$PROJECTS_CATEGORY_ID" || warn "Doesn't look like a valid Discord ID"; }

existing_github=$(existing_cfg '.user.github_username')
if [ -n "$existing_github" ]; then
    echo ""
    read -rp "  GitHub username [$existing_github]: " GITHUB_USERNAME
    GITHUB_USERNAME=$(trim "$GITHUB_USERNAME")
    [ -z "$GITHUB_USERNAME" ] && GITHUB_USERNAME="$existing_github"
else
    GITHUB_USERNAME=$(prompt_value "GitHub username (for repo creation, or Enter to skip)")
    [ -z "$GITHUB_USERNAME" ] && warn "Skipped — you'll need this for 'gh repo create'"
fi

echo ""
info "${BOLD}Manager Bot${RESET}"

collect_bot_token "Manager" "$(existing_cfg '.tokens.manager')"
MANAGER_TOKEN="$COLLECTED_TOKEN"
MANAGER_BOT_USER_ID="${COLLECTED_BOT_USER_ID:-}"

if [ -z "$MANAGER_BOT_USER_ID" ]; then
    MANAGER_BOT_USER_ID=$(prompt_or_keep_id "Manager bot user ID (right-click bot in server → Copy ID)" "$(existing_cfg '.bots.manager.discord_user_id')")
fi

# Collect worker tokens and IDs
declare -a WORKER_TOKENS
declare -a WORKER_BOT_USER_IDS

for i in $(seq 1 "$NUM_WORKERS"); do
    echo ""
    info "${BOLD}Worker-$i Bot${RESET}"

    collect_bot_token "Worker-$i" "$(existing_cfg ".tokens[\"worker-$i\"]")"
    WORKER_TOKENS+=("$COLLECTED_TOKEN")

    bot_user_id="${COLLECTED_BOT_USER_ID:-}"
    if [ -z "$bot_user_id" ]; then
        bot_user_id=$(prompt_or_keep_id "Worker-$i bot user ID" "$(existing_cfg ".bots[\"worker-$i\"].discord_user_id")")
    fi
    WORKER_BOT_USER_IDS+=("$bot_user_id")
done

echo ""
info "${BOLD}Optional Tokens${RESET} (press Enter to skip/keep existing)"

existing_vercel=$(existing_cfg '.tokens.vercel')
if [ -n "$existing_vercel" ]; then
    info "  Vercel token: (already set, press Enter to keep)"
    read -rsp "  Vercel token [keep existing]: " VERCEL_TOKEN
    echo "" >&2
    VERCEL_TOKEN=$(trim "$VERCEL_TOKEN")
    [ -z "$VERCEL_TOKEN" ] && VERCEL_TOKEN="$existing_vercel"
else
    VERCEL_TOKEN=$(prompt_secret "Vercel token (optional, for deploys)")
fi

existing_replicate=$(existing_cfg '.tokens.replicate')
if [ -n "$existing_replicate" ]; then
    info "  Replicate token: (already set, press Enter to keep)"
    read -rsp "  Replicate API token [keep existing]: " REPLICATE_TOKEN
    echo "" >&2
    REPLICATE_TOKEN=$(trim "$REPLICATE_TOKEN")
    [ -z "$REPLICATE_TOKEN" ] && REPLICATE_TOKEN="$existing_replicate"
else
    REPLICATE_TOKEN=$(prompt_secret "Replicate API token (optional, for image gen)")
fi

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

# Build settings.json (always write — values were confirmed in review step)

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

# Build bots.json — preserve existing project entries and active attunements
if [ -f "$BOTS_JSON" ] && jq empty "$BOTS_JSON" 2>/dev/null; then
    # Merge: keep existing projects and update workers list
    BOTS=$(cat "$BOTS_JSON")

    # Ensure all workers exist (add missing ones, don't reset existing)
    for i in $(seq 1 "$NUM_WORKERS"); do
        has_worker=$(printf '%s\n' "$BOTS" | jq -r ".workers[\"worker-$i\"] // empty" 2>/dev/null)
        if [ -z "$has_worker" ]; then
            BOTS=$(printf '%s\n' "$BOTS" | jq --arg name "worker-$i" \
                '.workers[$name] = {assigned_project: null, assigned_channel: null, status: "idle"}')
        fi
    done

    printf '%s\n' "$BOTS" | jq '.' > "${BOTS_JSON}.tmp" && mv "${BOTS_JSON}.tmp" "$BOTS_JSON"
    success "bots.json updated (existing projects and attunements preserved)"
else
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

fi  # end RESUME_MODE=false block

# ============================================================
header "Step 5a: Claude Code Trust"
# ============================================================

echo -e "  Pre-accepting Claude Code trust dialogs so bots can run headless."
echo -e "  (This prevents interactive prompts from blocking tmux sessions.)"

CLAUDE_JSON="$HOME/.claude.json"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

# Set global skipDangerousModePermissionPrompt
if [ -f "$CLAUDE_SETTINGS" ]; then
    skip_prompt=$(jq -r '.skipDangerousModePermissionPrompt // false' "$CLAUDE_SETTINGS" 2>/dev/null)
    if [ "$skip_prompt" != "true" ]; then
        jq '.skipDangerousModePermissionPrompt = true' "$CLAUDE_SETTINGS" > "${CLAUDE_SETTINGS}.tmp" \
            && mv "${CLAUDE_SETTINGS}.tmp" "$CLAUDE_SETTINGS" 2>/dev/null && success "skipDangerousModePermissionPrompt set" || warn "Could not update Claude settings"
    else
        success "skipDangerousModePermissionPrompt already set"
    fi
else
    warn "~/.claude/settings.json not found — Claude Code may not be installed yet"
fi

# Pre-accept trust for Cantrip root (manager working directory)
if [ -f "$CLAUDE_JSON" ]; then
    current_trust=$(jq -r ".projects[\"$CANTRIP_ROOT\"].hasTrustDialogAccepted // false" "$CLAUDE_JSON" 2>/dev/null)
    if [ "$current_trust" != "true" ]; then
        updated=$(jq --arg path "$CANTRIP_ROOT" '
            .projects[$path] = (.projects[$path] // {}) |
            .projects[$path].hasTrustDialogAccepted = true |
            .projects[$path].hasCompletedProjectOnboarding = true |
            .projects[$path].allowedTools = (.projects[$path].allowedTools // []) |
            .projects[$path].enabledMcpjsonServers = (.projects[$path].enabledMcpjsonServers // []) |
            .projects[$path].disabledMcpjsonServers = (.projects[$path].disabledMcpjsonServers // [])
        ' "$CLAUDE_JSON" 2>/dev/null)
        if printf '%s\n' "$updated" | jq empty 2>/dev/null; then
            printf '%s\n' "$updated" > "${CLAUDE_JSON}.tmp" && mv "${CLAUDE_JSON}.tmp" "$CLAUDE_JSON"
            success "Trust pre-accepted for $CANTRIP_ROOT"
        else
            warn "Could not update ~/.claude.json"
        fi
    else
        success "Trust already accepted for $CANTRIP_ROOT"
    fi

    # Also pre-accept trust for any existing project directories
    if [ -d "$CANTRIP_ROOT/projects" ]; then
        for proj_dir in "$CANTRIP_ROOT/projects"/*/; do
            [ -d "$proj_dir" ] || continue
            proj_dir="${proj_dir%/}"  # Remove trailing slash
            proj_trust=$(jq -r ".projects[\"$proj_dir\"].hasTrustDialogAccepted // false" "$CLAUDE_JSON" 2>/dev/null)
            if [ "$proj_trust" != "true" ]; then
                updated=$(jq --arg path "$proj_dir" '
                    .projects[$path] = (.projects[$path] // {}) |
                    .projects[$path].hasTrustDialogAccepted = true |
                    .projects[$path].hasCompletedProjectOnboarding = true |
                    .projects[$path].allowedTools = (.projects[$path].allowedTools // []) |
                    .projects[$path].enabledMcpjsonServers = (.projects[$path].enabledMcpjsonServers // []) |
                    .projects[$path].disabledMcpjsonServers = (.projects[$path].disabledMcpjsonServers // [])
                ' "$CLAUDE_JSON" 2>/dev/null)
                if printf '%s\n' "$updated" | jq empty 2>/dev/null; then
                    printf '%s\n' "$updated" > "${CLAUDE_JSON}.tmp" && mv "${CLAUDE_JSON}.tmp" "$CLAUDE_JSON"
                    success "Trust pre-accepted for $proj_dir"
                fi
            else
                success "Trust already accepted for $proj_dir"
            fi
        done
    fi
else
    warn "~/.claude.json not found — trust will be set when bots first launch"
fi

# ============================================================
header "Step 5b: Discord Roles & Permissions (Optional)"
# ============================================================

echo -e "  Cantrip can auto-create Discord roles for each bot and lock down"
echo -e "  channel permissions so workers only see their assigned channels."
echo -e "  This uses the manager bot's token (requires Manage Roles + Manage Channels)."
echo -e ""
echo -e "  You can skip this and set up roles manually later."

if prompt_yesno "Auto-create bot roles and set #manager permissions?"; then
    # Load manager token (might be from resume mode or freshly set)
    if [ -z "${MANAGER_TOKEN:-}" ]; then
        MANAGER_TOKEN=$(jq -r '.tokens.manager // empty' "$CANTRIP_CONFIG" 2>/dev/null)
    fi
    if [ -z "${SERVER_ID:-}" ]; then
        SERVER_ID=$(jq -r '.discord.server_id // empty' "$CANTRIP_CONFIG" 2>/dev/null)
    fi
    if [ -z "${MANAGER_CHANNEL_ID:-}" ]; then
        MANAGER_CHANNEL_ID=$(jq -r '.discord.manager_channel_id // empty' "$CANTRIP_CONFIG" 2>/dev/null)
    fi

    if [ -z "$MANAGER_TOKEN" ] || [ -z "$SERVER_ID" ]; then
        warn "Manager token or server ID missing — skipping role creation."
    else
        DISCORD_API="https://discord.com/api/v10"
        AUTH_HEADER="Authorization: Bot $MANAGER_TOKEN"
        ROLE_CREATION_OK=true

        # Determine how many workers to create roles for
        if [ -z "${NUM_WORKERS:-}" ]; then
            NUM_WORKERS=$(jq -r '[.tokens | keys[] | select(startswith("worker-"))] | length' "$CANTRIP_CONFIG" 2>/dev/null || echo "0")
            TOTAL_BOTS=$((NUM_WORKERS + 1))
        fi

        ALL_BOT_NAMES=("manager")
        for i in $(seq 1 "$NUM_WORKERS"); do
            ALL_BOT_NAMES+=("worker-$i")
        done

        # Create a role for each bot (role IDs stored in settings.json as we go)
        for bot_name in "${ALL_BOT_NAMES[@]}"; do
            # Check if role already exists in settings.json
            existing_role=$(jq -r ".bots[\"$bot_name\"].discord_role_id // empty" "$CANTRIP_CONFIG" 2>/dev/null || echo "")
            if [ -n "$existing_role" ] && [ "$existing_role" != "null" ]; then
                pass "$bot_name — role already exists ($existing_role)"
                continue
            fi

            # Create role via Discord API
            role_response=$(curl -s -w "\n%{http_code}" \
                -H "$AUTH_HEADER" \
                -H "Content-Type: application/json" \
                -X POST "$DISCORD_API/guilds/$SERVER_ID/roles" \
                -d "$(jq -n --arg name "Cantrip-${bot_name}" '{name: $name, permissions: "0", mentionable: false}')" \
                2>/dev/null || echo -e "\n000")

            role_http=$(echo "$role_response" | tail -1)
            role_body=$(echo "$role_response" | sed '$d')

            if [ "$role_http" = "200" ]; then
                role_id=$(echo "$role_body" | jq -r '.id // empty' 2>/dev/null || echo "")
                if [ -n "$role_id" ]; then
                    pass "$bot_name — role created (Cantrip-${bot_name}, ID: $role_id)"

                    # Save role ID to settings.json immediately
                    UPDATED=$(jq --arg name "$bot_name" --arg rid "$role_id" \
                        '.bots[$name].discord_role_id = $rid' "$CANTRIP_CONFIG")
                    printf '%s\n' "$UPDATED" | jq '.' > "${CANTRIP_CONFIG}.tmp" && mv "${CANTRIP_CONFIG}.tmp" "$CANTRIP_CONFIG"
                else
                    warn "$bot_name — role created but couldn't parse ID"
                    ROLE_CREATION_OK=false
                fi
            elif [ "$role_http" = "403" ]; then
                warn "$bot_name — permission denied. Manager bot needs 'Manage Roles' permission."
                ROLE_CREATION_OK=false
                break
            else
                warn "$bot_name — failed to create role (HTTP $role_http)"
                ROLE_CREATION_OK=false
            fi
        done

        # Assign roles to bot users (read role IDs back from settings.json)
        if [ "$ROLE_CREATION_OK" = true ]; then
            echo ""
            info "Assigning roles to bot users..."

            for bot_name in "${ALL_BOT_NAMES[@]}"; do
                bot_uid=$(jq -r ".bots[\"$bot_name\"].discord_user_id // empty" "$CANTRIP_CONFIG" 2>/dev/null || echo "")
                role_id=$(jq -r ".bots[\"$bot_name\"].discord_role_id // empty" "$CANTRIP_CONFIG" 2>/dev/null || echo "")

                if [ -z "$bot_uid" ] || [ -z "$role_id" ]; then
                    warn "$bot_name — skipping role assignment (missing user ID or role ID)"
                    continue
                fi

                assign_http=$(curl -s -o /dev/null -w "%{http_code}" \
                    -H "$AUTH_HEADER" \
                    -H "Content-Type: application/json" \
                    -X PUT "$DISCORD_API/guilds/$SERVER_ID/members/$bot_uid/roles/$role_id" \
                    2>/dev/null || echo "000")

                if [ "$assign_http" = "204" ] || [ "$assign_http" = "200" ]; then
                    pass "$bot_name — role assigned"
                elif [ "$assign_http" = "403" ]; then
                    warn "$bot_name — permission denied assigning role. Check bot hierarchy."
                else
                    warn "$bot_name — failed to assign role (HTTP $assign_http)"
                fi
            done
        fi

        # Set #manager channel permissions: all bots can view + send
        if [ "$ROLE_CREATION_OK" = true ] && [ -n "${MANAGER_CHANNEL_ID:-}" ]; then
            echo ""
            info "Setting #manager channel permissions..."

            for bot_name in "${ALL_BOT_NAMES[@]}"; do
                role_id=$(jq -r ".bots[\"$bot_name\"].discord_role_id // empty" "$CANTRIP_CONFIG" 2>/dev/null || echo "")
                [ -z "$role_id" ] && continue

                # Allow: View Channel (1024) + Send Messages (2048) + Read History (65536) = 68608
                perm_http=$(curl -s -o /dev/null -w "%{http_code}" \
                    -H "$AUTH_HEADER" \
                    -H "Content-Type: application/json" \
                    -X PUT "$DISCORD_API/channels/$MANAGER_CHANNEL_ID/permissions/$role_id" \
                    -d '{"allow": "68608", "deny": "0", "type": 0}' \
                    2>/dev/null || echo "000")

                if [ "$perm_http" = "204" ] || [ "$perm_http" = "200" ]; then
                    pass "$bot_name — #manager access granted"
                elif [ "$perm_http" = "403" ]; then
                    warn "$bot_name — permission denied. Manager bot needs 'Manage Channels'."
                    break
                else
                    warn "$bot_name — failed to set permissions (HTTP $perm_http)"
                fi
            done
        fi
    fi
else
    info "Skipped. You can set up roles later — see config/discord-setup.md Step 3."
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
