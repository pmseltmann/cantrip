#!/usr/bin/env bash
#
# Deep health check for all Cantrip bot sessions
# Unlike status.sh which only checks tmux sessions, this detects zombie sessions
# where tmux is alive but the claude process inside has crashed.
#
# Usage: ./health.sh

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v tmux &>/dev/null; then
    echo "ERROR: tmux is not installed."
    exit 1
fi

# --- Counters ---
total=0
healthy=0
zombie=0
down=0
mismatches=0

# --- Helpers ---

check_claude_in_session() {
    # Given a tmux session name, check if a claude process is running inside.
    # Returns 0 if found, 1 if not.
    # Walks the full process tree (not just 2 levels) by iterating descendants.
    # Note: only checks the first pane in the session.
    local session="$1"
    local pane_pid
    pane_pid=$(tmux list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null | head -1)
    if [ -z "$pane_pid" ]; then
        return 1
    fi

    # Collect all descendant PIDs by walking the tree iteratively
    local current_pids="$pane_pid"
    local all_pids="$pane_pid"
    while [ -n "$current_pids" ]; do
        local next_pids=""
        for pid in $current_pids; do
            local children
            children=$(pgrep -P "$pid" 2>/dev/null || true)
            if [ -n "$children" ]; then
                next_pids="$next_pids $children"
                all_pids="$all_pids $children"
            fi
        done
        current_pids=$(echo "$next_pids" | xargs)
    done

    # Check if any descendant's command line contains "claude"
    for pid in $all_pids; do
        local cmdline
        cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
        if [[ "$cmdline" == *claude* ]]; then
            return 0
        fi
    done
    return 1
}

check_session() {
    # Check a single tmux session and print its health status.
    # Args: session_name label
    local session="$1"
    local label="$2"
    total=$((total + 1))

    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "  DOWN    $label"
        down=$((down + 1))
        return 2
    fi

    if check_claude_in_session "$session"; then
        echo "  HEALTHY $label"
        healthy=$((healthy + 1))
        return 0
    else
        echo "  ZOMBIE  $label  (tmux alive, no claude process)"
        zombie=$((zombie + 1))
        return 1
    fi
}

# --- Main ---

echo "=== Cantrip Health Check ==="
echo ""

# Check manager
echo "Manager:"
check_session "cantrip-manager" "cantrip-manager"
echo ""

# Check workers
echo "Workers:"
for worker_id in $(jq -r '.workers | keys[]' "$BOTS_JSON"); do
    session="cantrip-$worker_id"
    check_session "$session" "$session"
done
echo ""

# Cross-reference with bots.json attunements
echo "Attunement Cross-Check:"
has_issues=false
for worker_id in $(jq -r '.workers | keys[]' "$BOTS_JSON"); do
    session="cantrip-$worker_id"
    bots_status=$(jq -r ".workers[\"$worker_id\"].status // \"unknown\"" "$BOTS_JSON")
    project=$(jq -r ".workers[\"$worker_id\"].assigned_project // empty" "$BOTS_JSON")

    if [ "$bots_status" = "active" ] || [ -n "$project" ]; then
        # Worker is marked as active or has an assigned project -- verify it's healthy
        if ! tmux has-session -t "$session" 2>/dev/null; then
            echo "  MISMATCH $worker_id: bots.json says active on '$project' but session is DOWN"
            mismatches=$((mismatches + 1))
            has_issues=true
        elif ! check_claude_in_session "$session"; then
            echo "  MISMATCH $worker_id: bots.json says active on '$project' but session is ZOMBIE"
            mismatches=$((mismatches + 1))
            has_issues=true
        fi
    fi
done
if [ "$has_issues" = false ]; then
    echo "  All attunements consistent."
fi
echo ""

# Check caffeinate
echo "Sleep Prevention:"
caffeinate_pid_file="$CANTRIP_ROOT/.caffeinate.pid"
if [ -f "$caffeinate_pid_file" ]; then
    caf_pid=$(cat "$caffeinate_pid_file" 2>/dev/null || echo "")
    if [ -n "$caf_pid" ] && kill -0 "$caf_pid" 2>/dev/null; then
        echo "  ACTIVE   caffeinate (PID $caf_pid)"
    else
        echo "  STALE    caffeinate PID file exists but process $caf_pid is dead"
    fi
else
    echo "  INACTIVE no caffeinate PID file found"
fi
echo ""

# Summary
echo "--- Summary ---"
echo "  Total sessions: $total"
echo "  Healthy: $healthy  |  Zombie: $zombie  |  Down: $down"
if [ "$mismatches" -gt 0 ]; then
    echo "  Attunement mismatches: $mismatches"
fi
if [ "$zombie" -gt 0 ] || [ "$mismatches" -gt 0 ]; then
    echo ""
    echo "  Action needed: restart zombie/mismatched workers with start-worker.sh"
fi
