#!/usr/bin/env bash
#
# Remove a project from Cantrip
# Stops any attuned familiar, removes from bots.json, optionally deletes Discord channel and archives repo
#
# Usage: ./remove-project.sh <project-name> [options]
#
# Options:
#   --delete-channel    Delete the Discord channel
#   --archive-repo      Archive the GitHub repo
#   --delete-files      Delete the project folder (otherwise just de-registers it)
#
# Example:
#   ./remove-project.sh old-project --delete-channel --archive-repo

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <project-name> [--delete-channel] [--archive-repo] [--delete-files]"
    exit 1
fi

PROJECT_NAME="$1"
shift

DELETE_CHANNEL=false
ARCHIVE_REPO=false
DELETE_FILES=false

while [ $# -gt 0 ]; do
    case "$1" in
        --delete-channel) DELETE_CHANNEL=true; shift ;;
        --archive-repo)   ARCHIVE_REPO=true; shift ;;
        --delete-files)   DELETE_FILES=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

PROJECT_DIR="$CANTRIP_ROOT/projects/$PROJECT_NAME"

echo "=== Cantrip: Removing project '$PROJECT_NAME' ==="
echo ""

# --- Step 1: Stop any attuned familiar ---

echo "1/5  Checking for attuned familiars..."
if [ -f "$BOTS_JSON" ]; then
    for worker_id in $(jq -r '.workers | keys[]' "$BOTS_JSON"); do
        assigned=$(jq -r ".workers[\"$worker_id\"].assigned_project // empty" "$BOTS_JSON")
        if [ "$assigned" = "$PROJECT_NAME" ]; then
            SESSION_NAME="cantrip-$worker_id"
            if command -v tmux &> /dev/null && tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
                echo "     Stopping $worker_id (session: $SESSION_NAME)..."
                tmux kill-session -t "$SESSION_NAME"
            fi
            # Clear the attunement in bots.json
            bots_json_update ".workers[\"$worker_id\"].assigned_project = null | .workers[\"$worker_id\"].assigned_channel = null | .workers[\"$worker_id\"].status = \"idle\""
            echo "     $worker_id released"
        fi
    done
fi

# --- Step 2: Delete Discord channel ---

if [ "$DELETE_CHANNEL" = true ]; then
    echo "2/5  Deleting Discord channel..."
    CHANNEL_ID=$(bots_project_channel_id "$PROJECT_NAME")
    MANAGER_TOKEN=$(cfg_token "manager")

    if [ -n "$CHANNEL_ID" ] && [ -n "$MANAGER_TOKEN" ]; then
        RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
            "https://discord.com/api/v10/channels/$CHANNEL_ID" \
            -H "Authorization: Bot $MANAGER_TOKEN")
        if [ "$RESPONSE" = "200" ] || [ "$RESPONSE" = "204" ]; then
            echo "     Channel #$PROJECT_NAME deleted"
        else
            echo "     WARNING: Failed to delete channel (HTTP $RESPONSE)"
        fi
    else
        echo "     No channel ID or manager token available"
    fi
else
    echo "2/5  Skipping channel deletion (use --delete-channel)"
fi

# --- Step 3: Archive GitHub repo ---

if [ "$ARCHIVE_REPO" = true ]; then
    echo "3/5  Archiving GitHub repo..."
    REPO_URL=$(jq -r ".projects[\"$PROJECT_NAME\"].repo_url // empty" "$BOTS_JSON" 2>/dev/null)
    if [ -n "$REPO_URL" ] && command -v gh &> /dev/null; then
        REPO_NAME=$(echo "$REPO_URL" | sed -e 's|^https://github.com/||' -e 's|^git@github.com:||' -e 's|\.git$||' -e 's|/$||')
        if gh repo archive "$REPO_NAME" --yes 2>/dev/null; then
            echo "     Repo archived: $REPO_NAME"
        else
            echo "     WARNING: Failed to archive repo"
        fi
    else
        echo "     No repo URL found or gh not available"
    fi
else
    echo "3/5  Skipping repo archive (use --archive-repo)"
fi

# --- Step 4: Remove from bots.json ---

echo "4/5  Removing from bots.json..."
if [ -f "$BOTS_JSON" ]; then
    EXISTING=$(jq -r ".projects[\"$PROJECT_NAME\"] // empty" "$BOTS_JSON")
    if [ -n "$EXISTING" ]; then
        bots_json_update "del(.projects[\"$PROJECT_NAME\"])"
        echo "     Removed from bots.json"
    else
        echo "     Project not found in bots.json"
    fi
fi

# --- Step 5: Delete project files ---

if [ "$DELETE_FILES" = true ]; then
    echo "5/5  Deleting project files..."
    if [ -d "$PROJECT_DIR" ]; then
        rm -rf "$PROJECT_DIR"
        echo "     Deleted: $PROJECT_DIR"
    else
        echo "     Directory not found: $PROJECT_DIR"
    fi
else
    echo "5/5  Keeping project files at $PROJECT_DIR (use --delete-files to remove)"
fi

echo ""
echo "=== Project '$PROJECT_NAME' removed ==="
