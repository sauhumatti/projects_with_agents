#!/bin/bash
# Agent Dispatch Functions
# Spawns AI agents to work on tasks

# Enable nullglob
shopt -s nullglob

# Dispatch agents for pending tasks
# Uses dependency-based scheduling: tasks run when ALL dependencies are complete
dispatch_agents() {
    local tasks_file="$STATUS_DIR/tasks.json"

    if [ ! -f "$tasks_file" ]; then
        log_warn "No tasks file found"
        return
    fi

    # Use Python to parse JSON and find tasks ready to dispatch (dependencies met)
    local tasks_to_dispatch=$(python3 << PYEOF
import json
import os
import sys

status_dir = "$STATUS_DIR"
tasks_file = "$tasks_file"

def is_task_complete(task_id, status_dir):
    """Check if a specific task is completed (merged or approved)"""
    completed_file = os.path.join(status_dir, f"{task_id}.completed")
    approved_file = os.path.join(status_dir, f"{task_id}.approved")
    merged_file = os.path.join(status_dir, f"{task_id}.merged")
    return os.path.exists(completed_file) or os.path.exists(approved_file) or os.path.exists(merged_file)

def is_task_in_progress(task_id, status_dir):
    """Check if a task is currently running"""
    status_file = os.path.join(status_dir, f"{task_id}.status")
    return os.path.exists(status_file)

def are_dependencies_met(task, status_dir):
    """Check if ALL dependencies for a task are complete"""
    depends_on = task.get('depends_on', [])
    if not depends_on:
        return True  # No dependencies = ready to run

    for dep_id in depends_on:
        if not is_task_complete(dep_id, status_dir):
            return False
    return True

try:
    with open(tasks_file, 'r') as f:
        data = json.load(f)

    tasks = data.get('tasks', [])

    # Count stats for logging
    ready_count = 0
    blocked_count = 0
    running_count = 0
    complete_count = 0

    for task in tasks:
        task_id = task.get('id', '')
        status = task.get('status', '')

        # Skip completed or failed tasks
        if status in ['completed', 'failed']:
            complete_count += 1
            continue

        # Skip if already in progress or completed
        if is_task_complete(task_id, status_dir):
            complete_count += 1
            continue

        if is_task_in_progress(task_id, status_dir):
            running_count += 1
            continue

        # Check if dependencies are met
        if not are_dependencies_met(task, status_dir):
            blocked_count += 1
            continue

        # This task is ready to dispatch!
        ready_count += 1
        branch = task.get('branch', '')
        agent = task.get('agent', '')
        task_type = task.get('type', 'implement')
        description = task.get('description', '').replace("'", "\\'")

        print(f"{task_id}|{branch}|{agent}|{task_type}|{description}")

    # Log status to stderr
    print(f"[Tasks: {complete_count} done, {running_count} running, {ready_count} ready, {blocked_count} blocked]", file=sys.stderr)

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
PYEOF
)

    if [ -z "$tasks_to_dispatch" ]; then
        return
    fi

    local task_count=0
    local assigned_to_pool=0

    # Process each ready task
    while IFS='|' read -r task_id branch agent task_type description; do
        if [ -n "$task_id" ] && [ -n "$agent" ]; then
            # First, try to assign to a waiting agent in the pool
            if try_assign_to_pool "$task_id" "$branch" "$task_type" "$description" "$task_type"; then
                log "Assigned $task_id to pooled agent"
                assigned_to_pool=$((assigned_to_pool + 1))

                # Create status file to mark task as in-progress
                local status_file="$STATUS_DIR/${task_id}.status"
                cat > "$status_file" <<EOF
task: $task_id
agent: pooled
branch: $branch
started: $(date -Iseconds)
status: assigned_to_pool
EOF
            else
                # No pooled agent available, spawn a new one
                log "Dispatching new $agent for $task_type task: $task_id"
                dispatch_single_agent "$task_id" "$branch" "$agent" "$description" &
                task_count=$((task_count + 1))
            fi

            # Respect parallel limit (count both pooled and new)
            if [ $((task_count + assigned_to_pool)) -ge $MAX_PARALLEL_AGENTS ]; then
                log_warn "Reached max parallel agents ($MAX_PARALLEL_AGENTS)"
                break
            fi
        fi
    done <<< "$tasks_to_dispatch"

    if [ $task_count -gt 0 ] || [ $assigned_to_pool -gt 0 ]; then
        log_success "Dispatched: $task_count new agents, $assigned_to_pool to pool"
        # Wait a bit for agents to start before next cycle
        sleep 5
    fi
}

# Dispatch a single agent
dispatch_single_agent() {
    local task_id="$1"
    local branch="$2"
    local agent="$3"
    local description="$4"

    local status_file="$STATUS_DIR/${task_id}.status"
    local log_file="$LOGS_DIR/${task_id}.log"
    local agent_workspace="$AGENTS_DIR/${task_id}"

    # Mark as in progress
    cat > "$status_file" <<EOF
task: $task_id
agent: $agent
branch: $branch
workspace: $agent_workspace
started: $(date -Iseconds)
status: running
EOF

    # Create agents directory if it doesn't exist
    mkdir -p "$AGENTS_DIR"

    # Clean up any previous workspace for this task
    rm -rf "$agent_workspace"

    # Clone the main workspace into agent's isolated directory
    log "Cloning workspace for $agent (task $task_id)..."
    git clone "$WORKSPACE" "$agent_workspace" 2>/dev/null
    if [ $? -ne 0 ]; then
        log_error "Failed to clone workspace for task $task_id"
        rm -f "$status_file"
        return 1
    fi

    # Ensure we have latest main branch
    cd "$agent_workspace"
    git checkout main 2>/dev/null || git checkout master 2>/dev/null || true
    git pull origin main 2>/dev/null || git pull origin master 2>/dev/null || true


    # Create feature branch FROM latest main
    git checkout -b "$branch" 2>/dev/null || git checkout "$branch" 2>/dev/null || true

    # Build list of available environment variables for the agent
    local env_info=""
    if [ -f "$RESOURCES_FILE" ]; then
        env_info="AVAILABLE ENVIRONMENT VARIABLES: $(grep -o '^[A-Z_]*=' "$RESOURCES_FILE" 2>/dev/null | tr -d '=' | tr '\n' ', ' || echo 'none')"
    fi

    # Calculate unique port for this task's dev server (base 3000 + task number)
    local task_num="${task_id##*-}"  # Extract number from "task-5" -> "5"
    task_num="${task_num:-1}"
    local dev_port=$((3000 + task_num))

    # Build the prompt for the agent
    local agent_prompt="You are working on a software project.

YOUR TASK: $description

WORKING DIRECTORY: $agent_workspace
$env_info

DEV SERVER INSTRUCTIONS:
- You have a dedicated port for testing: $dev_port
- If you need to test your work visually, start a dev server on port $dev_port
- Example: 'npm run dev -- --port $dev_port' or 'python -m http.server $dev_port'
- Then use chrome-devtools MCP to navigate to http://localhost:$dev_port

CHROME DEVTOOLS BROWSER AUTOMATION:
- Use chrome-devtools MCP tools (navigate_page, click, fill, take_snapshot, take_screenshot, etc.)
- take_snapshot: Get a text snapshot of the page based on a11y tree (preferred over screenshots)
- take_screenshot: Capture visual screenshot when needed
- list_console_messages: View console logs and errors
- list_network_requests: Monitor network activity
- evaluate_script: Run JavaScript in page context
- The browser runs in headless mode

COMMUNICATION WITH PROJECT MANAGER:
You report to the Project Manager (PM). You cannot contact the user directly.

Available messaging tools:
- ask_pm(question, context?, priority?) - Ask the PM for clarification. BLOCKS until PM responds.
- send_status(status, message, progress?) - Update PM on your progress (non-blocking)
- notify_pm(message, type?) - Send notification to PM (non-blocking). Type: info/warning/error/success
- get_messages() - Check for incoming messages from PM

USE ask_pm WHEN:
- You're unsure about requirements or approach
- You encounter an unexpected situation or blocker
- You need to make a significant decision
- You found an issue that affects other tasks
- You need approval before proceeding with something risky

The PM will escalate to the user if needed - that's not your concern.

PERSISTENT AGENT LIFECYCLE:
You are a persistent agent. After completing your task, you stay alive to receive more work.

Lifecycle tools:
- task_complete(summary, files_changed?) - Call when you finish your current task
- await_assignment(capabilities?) - Enter standby and wait for PM to assign new work

YOUR WORKFLOW:
1. Complete the task described above
2. Call task_complete() with a summary of what you did
3. Call await_assignment() with your capabilities (e.g., ['coding', 'testing', 'research'])
4. When you receive a new assignment, work on it
5. Repeat steps 2-4 until await_assignment() times out (10 min with no work)

IMPORTANT:
- Create the necessary files to complete this task
- Make sure your code is complete and working
- Use environment variables for any API keys or secrets - they are already set
- If testing with a dev server, make sure to kill it when done (or it will be cleaned up automatically)
- After each task, call task_complete() then await_assignment() to stay available for more work"

    # Dispatch based on agent type (with environment variables loaded)
    local result=""
    log "Running $agent for task: $task_id (in $agent_workspace)"

    # Load resources into environment for the agent subprocess
    if [ -f "$RESOURCES_FILE" ]; then
        set -a
        source "$RESOURCES_FILE"
        set +a
    fi

    # Set up messaging environment variables
    export ORCHESTRATOR_MESSAGES_DIR="$STATUS_DIR/messages"
    export ORCHESTRATOR_AGENT_ID="$agent-$task_id"
    export ORCHESTRATOR_TASK_ID="$task_id"
    mkdir -p "$ORCHESTRATOR_MESSAGES_DIR"

    case "$agent" in
        claude)
            result=$(cd "$agent_workspace" && $CLAUDE_CMD "$agent_prompt" 2>&1) || true
            ;;
        codex)
            result=$($CODEX_CMD -C "$agent_workspace" "$agent_prompt" 2>&1) || true
            ;;
        gemini)
            result=$(cd "$agent_workspace" && $GEMINI_CMD "$agent_prompt" 2>&1) || true
            ;;
        *)
            log_error "Unknown agent type: $agent"
            rm -f "$status_file"
            rm -rf "$agent_workspace"
            return 1
            ;;
    esac

    # Save result
    echo "$result" > "$log_file"

    # Check if agent created/modified files
    cd "$agent_workspace"
    local changes=$(git status --porcelain 2>/dev/null)

    if [ -n "$changes" ]; then
        # Stage and commit changes in agent's workspace
        git add -A
        git commit -m "Task $task_id: $description (by $agent)" 2>/dev/null || true

        # Push branch back to main workspace
        log "Pushing $branch back to main workspace..."
        git push origin "$branch" 2>/dev/null || {
            # If push fails, try adding as remote and push
            cd "$WORKSPACE"
            git fetch "$agent_workspace" "$branch:$branch" 2>/dev/null || true
            cd "$agent_workspace"
        }

        # Mark as completed
        cat > "${status_file%.status}.completed" <<EOF
task: $task_id
agent: $agent
branch: $branch
workspace: $agent_workspace
started: $(grep "started:" "$status_file" 2>/dev/null | cut -d: -f2- || echo "unknown")
completed: $(date -Iseconds)
status: completed
EOF
        rm -f "$status_file"

        log_success "Agent $agent completed task $task_id"
    else
        # No changes - might be a research task or error
        log_warn "Agent $agent produced no changes for task $task_id"
        # Write complete metadata (don't rely on status file existing - it may have been moved to .stuck)
        cat > "${status_file%.status}.completed" <<EOF
task: $task_id
agent: $agent
branch: $branch
workspace: $agent_workspace
started: $(grep "started:" "$status_file" 2>/dev/null | cut -d: -f2- || echo "unknown")
completed: $(date -Iseconds)
status: no_changes
EOF
        rm -f "$status_file"
    fi

    # Clean up agent workspace (optional - comment out to keep for debugging)
    # rm -rf "$agent_workspace"

    cd "$LAUNCH_DIR" 2>/dev/null || true
}

# Get task status summary (for display)
get_task_status() {
    local tasks_file="$STATUS_DIR/tasks.json"

    if [ ! -f "$tasks_file" ]; then
        echo "0|0|0|0"
        return
    fi

    # Use Python to count tasks by status
    python3 << PYEOF
import json
import os

status_dir = "$STATUS_DIR"
tasks_file = "$tasks_file"

def is_task_complete(task_id, status_dir):
    completed_file = os.path.join(status_dir, f"{task_id}.completed")
    approved_file = os.path.join(status_dir, f"{task_id}.approved")
    merged_file = os.path.join(status_dir, f"{task_id}.merged")
    return os.path.exists(completed_file) or os.path.exists(approved_file) or os.path.exists(merged_file)

def is_task_in_progress(task_id, status_dir):
    status_file = os.path.join(status_dir, f"{task_id}.status")
    return os.path.exists(status_file)

def are_dependencies_met(task, tasks_dict, status_dir):
    depends_on = task.get('depends_on', [])
    if not depends_on:
        return True
    for dep_id in depends_on:
        if not is_task_complete(dep_id, status_dir):
            return False
    return True

try:
    with open(tasks_file, 'r') as f:
        data = json.load(f)

    tasks = data.get('tasks', [])
    tasks_dict = {t['id']: t for t in tasks}

    complete = 0
    running = 0
    ready = 0
    blocked = 0

    for task in tasks:
        task_id = task.get('id', '')
        status = task.get('status', '')

        if status in ['completed', 'failed'] or is_task_complete(task_id, status_dir):
            complete += 1
        elif is_task_in_progress(task_id, status_dir):
            running += 1
        elif are_dependencies_met(task, tasks_dict, status_dir):
            ready += 1
        else:
            blocked += 1

    # Output: complete|running|ready|blocked
    print(f"{complete}|{running}|{ready}|{blocked}")

except Exception as e:
    print("0|0|0|0")
PYEOF
}

# Get pending tasks count (legacy, for compatibility)
get_pending_tasks() {
    local status=$(get_task_status)
    local ready=$(echo "$status" | cut -d'|' -f3)
    local blocked=$(echo "$status" | cut -d'|' -f4)
    local pending=$((ready + blocked))

    if [ "$pending" -gt 0 ]; then
        echo "$pending pending"
    fi
}
