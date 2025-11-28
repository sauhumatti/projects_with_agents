#!/bin/bash
# Agent Monitoring Functions
# Tracks agent status and detects completion/failures

# Enable nullglob to handle empty glob patterns
shopt -s nullglob

# Check for completed agents
check_completed_agents() {
    local completed=""

    for status_file in "$STATUS_DIR"/*.completed; do
        [ -f "$status_file" ] || continue
        local agent_id=$(basename "$status_file" .completed)
        completed="$completed $agent_id"
    done

    echo "$completed" | xargs
}

# Check for stuck agents (running too long)
check_stuck_agents() {
    local now=$(date +%s)

    for status_file in "$STATUS_DIR"/*.status; do
        [ -f "$status_file" ] || continue

        local started=$(grep "started:" "$status_file" | cut -d: -f2- | xargs)
        local started_ts=$(date -d "$started" +%s 2>/dev/null || echo 0)
        local elapsed=$((now - started_ts))

        if [ $elapsed -gt $AGENT_TIMEOUT ]; then
            local task_id=$(basename "$status_file" .status)
            log_warn "Agent for task $task_id appears stuck (${elapsed}s elapsed)"

            # Mark for retry
            mv "$status_file" "${status_file%.status}.stuck"
        fi
    done
}

# Check if project is complete
is_project_complete() {
    local tasks_file="$STATUS_DIR/tasks.json"

    if [ ! -f "$tasks_file" ]; then
        return 1
    fi

    # Count total tasks vs completed tasks
    local total_tasks=$(grep -c '"id"' "$tasks_file" 2>/dev/null || echo "0")
    local completed_tasks=$(grep -c '"status": "completed"' "$tasks_file" 2>/dev/null || echo "0")

    # Trim whitespace and ensure integers
    total_tasks=$(echo "$total_tasks" | tr -d '[:space:]')
    completed_tasks=$(echo "$completed_tasks" | tr -d '[:space:]')
    total_tasks=${total_tasks:-0}
    completed_tasks=${completed_tasks:-0}

    # Also check for any active status files
    local active_agents=$(ls "$STATUS_DIR"/*.status 2>/dev/null | wc -l | tr -d '[:space:]')
    local pending_completed=$(ls "$STATUS_DIR"/*.completed 2>/dev/null | wc -l | tr -d '[:space:]')
    active_agents=${active_agents:-0}
    pending_completed=${pending_completed:-0}

    if [ "$completed_tasks" -ge "$total_tasks" ] && [ "$active_agents" -eq 0 ] && [ "$pending_completed" -eq 0 ]; then
        return 0
    fi

    return 1
}

# Get detailed status report
get_status_report() {
    echo "=== Orchestrator Status Report ==="
    echo ""

    echo "Active Agents:"
    for status_file in "$STATUS_DIR"/*.status; do
        [ -f "$status_file" ] || continue
        echo "  - $(basename "$status_file" .status): $(grep "status:" "$status_file" | cut -d: -f2)"
    done
    echo ""

    echo "Completed (pending review):"
    for status_file in "$STATUS_DIR"/*.completed; do
        [ -f "$status_file" ] || continue
        echo "  - $(basename "$status_file" .completed)"
    done
    echo ""

    echo "Stuck Agents:"
    for status_file in "$STATUS_DIR"/*.stuck; do
        [ -f "$status_file" ] || continue
        echo "  - $(basename "$status_file" .stuck)"
    done
    echo ""
}

# Wait for any agent to complete
wait_for_completion() {
    local timeout=${1:-300}
    local start=$(date +%s)

    while true; do
        local completed=$(check_completed_agents)
        if [ -n "$completed" ]; then
            echo "$completed"
            return 0
        fi

        local now=$(date +%s)
        local elapsed=$((now - start))
        if [ $elapsed -gt $timeout ]; then
            return 1
        fi

        sleep 2
    done
}
