#!/usr/bin/env bash
#
# Cantrip preflight validation
# Checks that all prerequisites, config files, and required fields are in place
# before launching any bots.
#
# Usage: ./validate.sh

set -uo pipefail
# NOTE: We intentionally do NOT use set -e or source lib.sh here.
# lib.sh hard-exits on missing jq or settings.json, and set -e would kill
# the script on the first failed check. This script needs to report all
# failures, not crash on the first one.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANTRIP_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CANTRIP_CONFIG="$CANTRIP_ROOT/config/settings.json"
BOTS_JSON="$CANTRIP_ROOT/config/bots.json"
ACCESS_JSON="$HOME/.claude/channels/discord/access.json"

# --- State ---

FAILURES=0
WARNINGS=0

pass() {
    echo "  ✓ $1"
}

fail() {
    echo "  ✗ $1"
    FAILURES=$((FAILURES + 1))
}

warn() {
    echo "  ⚠ $1"
    WARNINGS=$((WARNINGS + 1))
}

validate_bot_token() {
    # Hit Discord API to verify the token. Returns 0 if valid, 1 if not.
    local token="$1"
    local response
    response=$(curl -s -w "\n%{http_code}" -H "Authorization: Bot $token" "https://discord.com/api/v10/users/@me" 2>/dev/null || echo "000")
    local http_code
    http_code=$(echo "$response" | tail -1)
    [ "$http_code" = "200" ]
}

# ============================================================
# 1. CLI Prerequisites
# ============================================================

echo "=== CLI Prerequisites ==="
echo ""

for cmd in tmux jq bun gh claude node; do
    if command -v "$cmd" &> /dev/null; then
        version=$("$cmd" --version 2>/dev/null | head -1 || echo "installed")
        pass "$cmd ($version)"
    else
        fail "$cmd — not found. Install before launching bots."
    fi
done

# Check gh authentication
if command -v gh &> /dev/null; then
    if gh auth status &>/dev/null; then
        pass "gh CLI — authenticated"
    else
        fail "gh CLI — not authenticated. Run: gh auth login"
    fi
fi

# Check projects directory
if [ -d "$CANTRIP_ROOT/projects" ]; then
    pass "projects/ directory exists"
else
    fail "projects/ directory missing"
fi

echo ""

# ============================================================
# 2. settings.json exists and parses
# ============================================================

echo "=== Config: settings.json ==="
echo ""

SETTINGS_OK=false

if [ ! -f "$CANTRIP_CONFIG" ]; then
    fail "settings.json not found at $CANTRIP_CONFIG"
    echo "       Copy config/settings.json.example and fill in your values."
else
    if jq empty "$CANTRIP_CONFIG" 2>/dev/null; then
        pass "settings.json exists and is valid JSON"
        SETTINGS_OK=true
    else
        fail "settings.json exists but is not valid JSON"
    fi
fi

echo ""

# ============================================================
# 3. Required fields in settings.json
# ============================================================

echo "=== Config: Required Fields ==="
echo ""

if [ "$SETTINGS_OK" = true ]; then
    # Helper: check that a jq path is present and non-null
    check_field() {
        local label="$1"
        local path="$2"
        local value
        value=$(jq -r "$path // empty" "$CANTRIP_CONFIG" 2>/dev/null || echo "")
        if [ -z "$value" ]; then
            fail "$label — missing or null"
        elif [[ "$value" == YOUR_* ]] || [[ "$value" == your-* ]] || [[ "$value" == paste-* ]]; then
            fail "$label — still set to placeholder value"
        else
            pass "$label"
        fi
    }

    check_field "discord.server_id" ".discord.server_id"
    check_field "discord.manager_channel_id" ".discord.manager_channel_id"
    check_field "user.discord_user_id" ".user.discord_user_id"
    check_field "tokens.manager" ".tokens.manager"

    # At least one worker token (excluding placeholders)
    worker_count=$(jq '[.tokens | to_entries[] | select(.key | startswith("worker-")) | select(.value != null and .value != "" and (.value | startswith("YOUR_") | not) and (.value | startswith("your-") | not))] | length' "$CANTRIP_CONFIG" 2>/dev/null || echo "0")
    if [ "$worker_count" -gt 0 ]; then
        pass "Worker tokens — $worker_count worker token(s) configured"
    else
        fail "Worker tokens — no worker tokens found in tokens.*"
    fi

    # Cross-check: every worker token should have a matching bot user ID
    for worker_name in $(jq -r '.tokens | keys[] | select(startswith("worker-"))' "$CANTRIP_CONFIG" 2>/dev/null); do
        bot_uid=$(jq -r ".bots[\"$worker_name\"].discord_user_id // empty" "$CANTRIP_CONFIG" 2>/dev/null || echo "")
        if [ -z "$bot_uid" ]; then
            fail "bots.$worker_name.discord_user_id — missing (token exists but no bot user ID)"
        fi
    done

    # Check manager bot user ID
    manager_bot_uid=$(jq -r '.bots.manager.discord_user_id // empty' "$CANTRIP_CONFIG" 2>/dev/null || echo "")
    if [ -z "$manager_bot_uid" ]; then
        fail "bots.manager.discord_user_id — missing"
    elif [[ "$manager_bot_uid" == YOUR_* ]]; then
        fail "bots.manager.discord_user_id — still set to placeholder value"
    else
        pass "bots.manager.discord_user_id"
    fi

    # Optional but useful fields
    github_user=$(jq -r '.user.github_username // empty' "$CANTRIP_CONFIG")
    if [ -z "$github_user" ]; then
        warn "user.github_username — not set (needed for repo creation)"
    fi
else
    fail "Skipping field checks — settings.json is missing or invalid"
fi

echo ""

# ============================================================
# 3b. Token Validation via Discord API
# ============================================================

echo "=== Token Validation (Discord API) ==="
echo ""

if [ "$SETTINGS_OK" = true ] && command -v curl &>/dev/null; then
    # Validate manager token
    manager_token=$(jq -r '.tokens.manager // empty' "$CANTRIP_CONFIG" 2>/dev/null || echo "")
    if [ -n "$manager_token" ] && [[ "$manager_token" != YOUR_* ]]; then
        if validate_bot_token "$manager_token"; then
            pass "Manager token — valid (Discord API confirmed)"
        else
            fail "Manager token — rejected by Discord API (expired, revoked, or incorrect)"
        fi
    else
        warn "Manager token — skipped (missing or placeholder)"
    fi

    # Validate worker tokens
    for worker_name in $(jq -r '.tokens | keys[] | select(startswith("worker-"))' "$CANTRIP_CONFIG" 2>/dev/null); do
        worker_token=$(jq -r ".tokens[\"$worker_name\"] // empty" "$CANTRIP_CONFIG" 2>/dev/null || echo "")
        if [ -n "$worker_token" ] && [[ "$worker_token" != YOUR_* ]]; then
            if validate_bot_token "$worker_token"; then
                pass "$worker_name token — valid (Discord API confirmed)"
            else
                fail "$worker_name token — rejected by Discord API (expired, revoked, or incorrect)"
            fi
        else
            warn "$worker_name token — skipped (missing or placeholder)"
        fi
    done
else
    if [ "$SETTINGS_OK" != true ]; then
        warn "Skipping token validation — settings.json is missing or invalid"
    else
        warn "Skipping token validation — curl not found"
    fi
fi

echo ""

# ============================================================
# 4. bots.json exists and parses
# ============================================================

echo "=== Config: bots.json ==="
echo ""

if [ ! -f "$BOTS_JSON" ]; then
    fail "bots.json not found at $BOTS_JSON"
    echo "       Copy config/bots.json.example to config/bots.json"
else
    if jq empty "$BOTS_JSON" 2>/dev/null; then
        pass "bots.json exists and is valid JSON"
        worker_count=$(jq '.workers | length' "$BOTS_JSON")
        pass "bots.json has $worker_count worker(s) registered"
    else
        fail "bots.json exists but is not valid JSON"
    fi
fi

echo ""

# ============================================================
# 5. Claude Code Discord plugin
# ============================================================

echo "=== Claude Code Discord Plugin ==="
echo ""

PLUGIN_FOUND=false

# Check known plugin locations
if [ -d "$HOME/.claude/plugins" ]; then
    for dir in "$HOME/.claude/plugins/"*discord* "$HOME/.claude/plugins/"*Discord*; do
        if [ -d "$dir" ] 2>/dev/null; then
            pass "Discord plugin found at $dir"
            PLUGIN_FOUND=true
            break
        fi
    done
fi

# Also check if the plugin is registered in Claude's config
if [ "$PLUGIN_FOUND" = false ] && [ -f "$HOME/.claude/plugins.json" ]; then
    if jq -e '.[] | select(.name | test("discord"; "i"))' "$HOME/.claude/plugins.json" &>/dev/null; then
        pass "Discord plugin registered in plugins.json"
        PLUGIN_FOUND=true
    fi
fi

if [ "$PLUGIN_FOUND" = false ]; then
    fail "Claude Code Discord plugin not found"
    echo "       Install with: claude plugin add <discord-plugin-path>"
fi

echo ""

# ============================================================
# 6. access.json
# ============================================================

echo "=== Channel Access Config ==="
echo ""

if [ -f "$ACCESS_JSON" ]; then
    if jq empty "$ACCESS_JSON" 2>/dev/null; then
        pass "access.json exists and is valid JSON"
        group_count=$(jq '.groups | length' "$ACCESS_JSON")
        pass "access.json has $group_count channel group(s) configured"
    else
        fail "access.json exists but is not valid JSON"
    fi
else
    fail "access.json not found at $ACCESS_JSON"
    echo "       This file controls which Discord channels the bots can access."
fi

echo ""

# ============================================================
# Summary
# ============================================================

echo "==========================================="

if [ "$FAILURES" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo "  ALL CHECKS PASSED — ready to launch"
elif [ "$FAILURES" -eq 0 ]; then
    echo "  PASSED with $WARNINGS warning(s)"
else
    echo "  FAILED — $FAILURES check(s) failed, $WARNINGS warning(s)"
fi

echo "==========================================="

if [ "$FAILURES" -gt 0 ]; then
    exit 1
fi

exit 0
