#!/usr/bin/env bash
#
# Shared library for Cantrip scripts
# Source this at the top of any script: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- Paths ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANTRIP_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CANTRIP_CONFIG="$CANTRIP_ROOT/config/settings.json"
BOTS_JSON="$CANTRIP_ROOT/config/bots.json"

# --- Preflight ---

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required. Install with: brew install jq"
    exit 1
fi

if [ ! -f "$CANTRIP_CONFIG" ]; then
    echo "ERROR: Config not found at $CANTRIP_CONFIG"
    echo "Copy config/settings.json.example and fill in your values."
    exit 1
fi

# --- Config readers ---
# These read from settings.json. All return empty string on missing values.

cfg() {
    # Generic config reader: cfg '.tokens.manager'
    jq -r "$1 // empty" "$CANTRIP_CONFIG"
}

cfg_token() {
    # Get a bot token by name: cfg_token "manager" or cfg_token "worker-1"
    jq -r ".tokens[\"$1\"] // empty" "$CANTRIP_CONFIG"
}

cfg_bot_user_id() {
    # Get a bot's Discord user ID: cfg_bot_user_id "worker-1"
    jq -r ".bots[\"$1\"].discord_user_id // empty" "$CANTRIP_CONFIG"
}

cfg_server_id() {
    cfg '.discord.server_id'
}

cfg_human_user_id() {
    cfg '.user.discord_user_id'
}

cfg_manager_channel_id() {
    cfg '.discord.manager_channel_id'
}

cfg_category_id() {
    cfg '.discord.projects_category_id'
}

cfg_github_username() {
    cfg '.user.github_username'
}

cfg_vercel_token() {
    cfg '.tokens.vercel'
}

# --- bots.json readers (runtime state) ---

bots_project_channel_id() {
    # Get a project's Discord channel ID from bots.json
    jq -r ".projects[\"$1\"].discord_channel_id // empty" "$BOTS_JSON"
}

# --- bots.json writer (locked) ---

BOTS_JSON_LOCK="$CANTRIP_ROOT/.bots-json.lock"

bots_json_update() {
    # Safely update bots.json with a jq filter, using a directory-based lock.
    # Usage: bots_json_update '.workers["worker-1"].status = "active"'
    local filter="$1"
    local retries=0

    while ! mkdir "$BOTS_JSON_LOCK" 2>/dev/null; do
        # Check for stale lock (holding process is dead)
        if [ -f "$BOTS_JSON_LOCK/pid" ]; then
            local lock_pid
            lock_pid=$(cat "$BOTS_JSON_LOCK/pid" 2>/dev/null || echo "")
            if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
                echo "WARNING: Breaking stale bots.json lock (PID $lock_pid is dead)" >&2
                rm -rf "$BOTS_JSON_LOCK"
                continue
            fi
        fi

        retries=$((retries + 1))
        if [ "$retries" -gt 20 ]; then
            echo "ERROR: Could not acquire bots.json lock after 2 seconds. Stale lock?" >&2
            echo "Remove $BOTS_JSON_LOCK manually if no other script is running." >&2
            return 1
        fi
        sleep 0.1  # macOS /bin/sleep supports fractional seconds
    done

    # Record holding PID for stale lock detection
    echo $$ > "$BOTS_JSON_LOCK/pid"

    # Use || rc=$? to guarantee lock release even under set -e
    local rc=0
    jq "$filter" "$BOTS_JSON" > "${BOTS_JSON}.tmp" && mv "${BOTS_JSON}.tmp" "$BOTS_JSON" || rc=$?
    rm -rf "$BOTS_JSON_LOCK"
    return "$rc"
}

# --- Claude Code trust pre-population ---

ensure_claude_trust() {
    # Pre-accept the Claude Code trust dialog for a given project directory.
    # This prevents interactive prompts from blocking headless tmux sessions.
    # Also ensures skipDangerousModePermissionPrompt is set globally.
    local project_path="$1"
    local claude_json="$HOME/.claude.json"
    local claude_settings="$HOME/.claude/settings.json"

    # Set global skipDangerousModePermissionPrompt if not already set
    if [ -f "$claude_settings" ]; then
        local skip_prompt
        skip_prompt=$(jq -r '.skipDangerousModePermissionPrompt // false' "$claude_settings" 2>/dev/null)
        if [ "$skip_prompt" != "true" ]; then
            jq '.skipDangerousModePermissionPrompt = true' "$claude_settings" > "${claude_settings}.tmp" \
                && mv "${claude_settings}.tmp" "$claude_settings" 2>/dev/null || true
        fi
    fi

    # Pre-accept project trust in ~/.claude.json
    if [ ! -f "$claude_json" ]; then
        return 0
    fi

    local current
    current=$(jq -r ".projects[\"$project_path\"].hasTrustDialogAccepted // false" "$claude_json" 2>/dev/null)
    if [ "$current" = "true" ]; then
        return 0
    fi

    local updated
    updated=$(jq --arg path "$project_path" '
        .projects[$path] = (.projects[$path] // {}) |
        .projects[$path].hasTrustDialogAccepted = true |
        .projects[$path].hasCompletedProjectOnboarding = true |
        .projects[$path].allowedTools = (.projects[$path].allowedTools // []) |
        .projects[$path].enabledMcpjsonServers = (.projects[$path].enabledMcpjsonServers // []) |
        .projects[$path].disabledMcpjsonServers = (.projects[$path].disabledMcpjsonServers // [])
    ' "$claude_json" 2>/dev/null)

    if printf '%s\n' "$updated" | jq empty 2>/dev/null; then
        printf '%s\n' "$updated" > "${claude_json}.tmp" && mv "${claude_json}.tmp" "$claude_json" 2>/dev/null || true
    fi
}

# --- Utilities ---

require_token() {
    # Require a bot token, exit with helpful message if missing
    local name="$1"
    local token
    token=$(cfg_token "$name")
    if [ -z "$token" ]; then
        echo "ERROR: No token for '$name' in $CANTRIP_CONFIG"
        echo "Set tokens.$name in settings.json"
        exit 1
    fi
    echo "$token"
}

