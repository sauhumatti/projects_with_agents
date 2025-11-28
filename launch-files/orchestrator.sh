#!/bin/bash
# Main Orchestrator - The Always-On Loop
# This script runs continuously and coordinates the PM and agents

# Don't exit on error - we handle errors ourselves
set +e

# Resolve symlinks to get the real script directory
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/lib/dispatch.sh"
source "$SCRIPT_DIR/lib/monitor.sh"
source "$SCRIPT_DIR/lib/pm.sh"
source "$SCRIPT_DIR/lib/messages.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Global state
SHUTDOWN_REQUESTED=false
ERROR_LOG="$LOGS_DIR/errors.log"
SESSION_LOG=""  # Set during init
# RESOURCES_FILE is defined in config.sh

# Sound notification - plays system beep and shows visual alert
notify_user() {
    local message="$1"
    local urgency="${2:-normal}"  # normal, urgent

    # WSL: Use PowerShell system beep (works reliably)
    if command -v powershell.exe &>/dev/null; then
        if [ "$urgency" = "urgent" ]; then
            # Urgent: 3 beeps with increasing pitch
            powershell.exe -c "[console]::beep(800,200); [console]::beep(1000,200); [console]::beep(1200,300)" 2>/dev/null &
        else
            # Normal: single beep
            powershell.exe -c "[console]::beep(1000,300)" 2>/dev/null &
        fi
    else
        # Fallback: terminal bell
        printf '\a'
        if [ "$urgency" = "urgent" ]; then
            sleep 0.2 && printf '\a'
            sleep 0.2 && printf '\a'
        fi
    fi

    # Linux: Try paplay for sound (PulseAudio)
    if command -v paplay &>/dev/null; then
        for sound in /usr/share/sounds/freedesktop/stereo/complete.oga \
                     /usr/share/sounds/freedesktop/stereo/message.oga; do
            if [ -f "$sound" ]; then
                paplay "$sound" 2>/dev/null &
                break
            fi
        done
    fi
}

# Prompt user for a resource (API key, credential, etc.)
# Usage: prompt_for_resource "OPENAI_API_KEY" "OpenAI API key for GPT access"
prompt_for_resource() {
    local var_name="$1"
    local description="$2"
    local is_secret="${3:-true}"

    notify_user "Need: $description" "urgent"

    echo -e "${CYAN}Resource needed:${NC} $description"
    echo -e "${CYAN}Variable name:${NC} $var_name"
    echo ""

    if [ "$is_secret" = "true" ]; then
        echo -n "Enter value (hidden): "
        read -rs value </dev/tty
        echo ""
    else
        echo -n "Enter value: "
        read -r value </dev/tty
    fi

    # Save to resources file
    mkdir -p "$(dirname "$RESOURCES_FILE")"

    # Remove old value if exists
    if [ -f "$RESOURCES_FILE" ]; then
        grep -v "^${var_name}=" "$RESOURCES_FILE" > "${RESOURCES_FILE}.tmp" 2>/dev/null || true
        mv "${RESOURCES_FILE}.tmp" "$RESOURCES_FILE"
    fi

    # Add new value
    echo "${var_name}=${value}" >> "$RESOURCES_FILE"
    chmod 600 "$RESOURCES_FILE"  # Secure permissions

    log_success "Saved $var_name"
    echo "$value"
}

# Check if a resource exists, prompt if not
# Returns the value
require_resource() {
    local var_name="$1"
    local description="$2"
    local is_secret="${3:-true}"

    # Check if already set in environment
    local current_value="${!var_name}"
    if [ -n "$current_value" ]; then
        echo "$current_value"
        return 0
    fi

    # Check resources file
    if [ -f "$RESOURCES_FILE" ]; then
        current_value=$(grep "^${var_name}=" "$RESOURCES_FILE" 2>/dev/null | cut -d= -f2-)
        if [ -n "$current_value" ]; then
            echo "$current_value"
            return 0
        fi
    fi

    # Prompt user
    prompt_for_resource "$var_name" "$description" "$is_secret"
}

# Load all saved resources into environment
load_resources() {
    if [ -f "$RESOURCES_FILE" ]; then
        set -a  # Auto-export
        source "$RESOURCES_FILE"
        set +a
        log "Loaded saved resources from $RESOURCES_FILE"
    fi
}

# Get resources as environment string for agents
get_resources_env() {
    if [ -f "$RESOURCES_FILE" ]; then
        cat "$RESOURCES_FILE" | tr '\n' ' '
    fi
}

# Write to session log (if initialized)
session_log() {
    local level="$1"
    local msg="$2"
    if [ -n "$SESSION_LOG" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" >> "$SESSION_LOG"
    fi
}

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"
    session_log "INFO" "$1"
}

log_success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $1"
    session_log "OK" "$1"
}

log_warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $1"
    session_log "WARN" "$1"
}

log_error() {
    local msg="$1"
    echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $msg"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $msg" >> "$ERROR_LOG"
    session_log "ERROR" "$msg"
}

log_fatal() {
    local msg="$1"
    local line="${2:-unknown}"
    echo -e "${RED}[$(date '+%H:%M:%S')] FATAL: $msg (line $line)${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FATAL at line $line: $msg" >> "$ERROR_LOG"
    session_log "FATAL" "$msg (line $line)"
}

# Log phase transitions
log_phase() {
    local phase="$1"
    local name="$2"
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  PHASE $phase: $name${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    session_log "PHASE" "=== PHASE $phase: $name ==="
}

# Progress display
show_progress() {
    local cycle="$1"

    # Get task status from dispatch module
    local status_line=$(get_task_status 2>/dev/null || echo "0|0|0|0")
    local complete=$(echo "$status_line" | cut -d'|' -f1)
    local running=$(echo "$status_line" | cut -d'|' -f2)
    local ready=$(echo "$status_line" | cut -d'|' -f3)
    local blocked=$(echo "$status_line" | cut -d'|' -f4)

    local total=$((complete + running + ready + blocked))

    # Build status bar
    local status_parts=""
    [ "$complete" -gt 0 ] && status_parts="${status_parts}${GREEN}✓${complete}${NC} "
    [ "$running" -gt 0 ] && status_parts="${status_parts}${YELLOW}▶${running}${NC} "
    [ "$ready" -gt 0 ] && status_parts="${status_parts}${CYAN}◉${ready}${NC} "
    [ "$blocked" -gt 0 ] && status_parts="${status_parts}${RED}◌${blocked}${NC} "

    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Cycle $cycle${NC} │ $status_parts│ Total: $complete/$total done  ${CYAN}${BOLD}║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${GREEN}✓${NC}=done ${YELLOW}▶${NC}=running ${CYAN}◉${NC}=ready ${RED}◌${NC}=blocked"

    # Show agent status updates if available
    local agent_status=$(get_agent_status_summary 2>/dev/null)
    if [ -n "$agent_status" ]; then
        echo ""
        echo -e "${YELLOW}Agent Status:${NC}"
        echo "$agent_status"
    fi

    # Show pending messages
    local pending_msgs=$(show_pending_messages 2>/dev/null)
    if [ -n "$pending_msgs" ]; then
        echo -e "${YELLOW}Messages:${NC}"
        echo "$pending_msgs"
    fi

    echo ""
}

# Save state for resume
save_state() {
    local state_file="$STATUS_DIR/orchestrator_state.json"
    local status_line=$(get_task_status 2>/dev/null || echo "0|0|0|0")
    cat > "$state_file" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "task_status": "$status_line",
    "status": "interrupted"
}
EOF
    log "State saved to $state_file"
}

# Graceful shutdown handler
shutdown_handler() {
    echo ""
    log_warn "Shutdown requested (Ctrl+C)..."
    SHUTDOWN_REQUESTED=true

    # Save state
    save_state

    # List running agents
    local running=$(ls "$STATUS_DIR"/*.status 2>/dev/null | wc -l | tr -d ' ')
    if [ "$running" -gt 0 ]; then
        log_warn "$running agents still running in background"
        log "Their work will be saved. Use './orchestrator.sh resume' to continue."
    fi

    log_success "Orchestrator stopped gracefully"
    exit 0
}

# Error handler
error_handler() {
    local line="$1"
    local cmd="$2"
    local code="$3"

    log_fatal "Command '$cmd' failed with exit code $code" "$line"

    # Don't exit - try to continue
    return 0
}

# Set up traps
trap shutdown_handler SIGINT SIGTERM
trap 'error_handler $LINENO "$BASH_COMMAND" $?' ERR

# Create a new project directory
create_project() {
    local description="$1"

    # Generate project name from description
    local project_slug=$(echo "$description" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-30 | sed 's/-$//')
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local project_name="${project_slug}_${timestamp}"

    # Set up project paths
    set_project_paths "$project_name"

    # Create directories
    mkdir -p "$PROJECTS_DIR"
    mkdir -p "$WORKSPACE" "$AGENTS_DIR" "$STATUS_DIR" "$LOGS_DIR"

    # Save project metadata
    cat > "$PROJECT_DIR/project.json" << EOF
{
    "name": "$project_name",
    "description": "$description",
    "created": "$(date -Iseconds)",
    "status": "active"
}
EOF

    echo "$project_name"
}

# Initialize a project (after create or select)
init_project() {
    # Create session log with timestamp
    SESSION_LOG="$LOGS_DIR/session_$(date '+%Y%m%d_%H%M%S').log"
    export SESSION_LOG
    ERROR_LOG="$LOGS_DIR/errors.log"

    echo "═══════════════════════════════════════════════════════════════════" > "$SESSION_LOG"
    echo "  ORCHESTRATOR SESSION LOG" >> "$SESSION_LOG"
    echo "  Project: $(basename "$PROJECT_DIR")" >> "$SESSION_LOG"
    echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')" >> "$SESSION_LOG"
    echo "  Working Directory: $WORKSPACE" >> "$SESSION_LOG"
    echo "═══════════════════════════════════════════════════════════════════" >> "$SESSION_LOG"
    echo "" >> "$SESSION_LOG"

    log "Project directory: $PROJECT_DIR"
    log "Session log: $SESSION_LOG"

    # Create error log
    touch "$ERROR_LOG"

    # Initialize git repo if not exists
    if [ ! -d "$WORKSPACE/.git" ]; then
        log "Initializing git repository in workspace..."
        cd "$WORKSPACE"
        git init
        git checkout -b main
        echo "# Multi-Agent Workspace" > README.md
        git add README.md
        git commit -m "Initial commit - orchestrator setup"
        cd "$SCRIPT_DIR"
    fi

    # Clear stale status files (running markers from interrupted sessions)
    rm -f "$STATUS_DIR"/*.status 2>/dev/null || true

    # Initialize messaging system
    init_messaging

    log_success "Project initialized"
}

# List all projects
list_projects() {
    echo ""
    echo -e "${BOLD}Available Projects${NC}"
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    if [ ! -d "$PROJECTS_DIR" ] || [ -z "$(ls -A "$PROJECTS_DIR" 2>/dev/null)" ]; then
        echo "  No projects found."
        echo ""
        echo "  Start a new project with: $0 start \"project description\""
        echo ""
        return
    fi

    local index=0
    for project_path in "$PROJECTS_DIR"/*/; do
        [ -d "$project_path" ] || continue
        index=$((index + 1))

        local project_name=$(basename "$project_path")
        local project_json="$project_path/project.json"
        local tasks_json="$project_path/status/tasks.json"

        # Get project info
        local description=""
        local created=""
        local status="unknown"

        if [ -f "$project_json" ]; then
            description=$(python3 -c "import json; print(json.load(open('$project_json')).get('description',''))" 2>/dev/null || echo "")
            created=$(python3 -c "import json; print(json.load(open('$project_json')).get('created','')[:10])" 2>/dev/null || echo "")
        fi

        # Count tasks
        local total_tasks=0
        local completed_tasks=0
        if [ -f "$tasks_json" ]; then
            total_tasks=$(python3 -c "import json; print(len(json.load(open('$tasks_json')).get('tasks',[])))" 2>/dev/null || echo 0)
            completed_tasks=$(grep -c '"status": "completed"' "$tasks_json" 2>/dev/null || echo 0)

            if [ "$completed_tasks" -ge "$total_tasks" ] && [ "$total_tasks" -gt 0 ]; then
                status="${GREEN}completed${NC}"
            else
                status="${YELLOW}in progress${NC} ($completed_tasks/$total_tasks tasks)"
            fi
        else
            status="${BLUE}new${NC}"
        fi

        echo -e "  ${BOLD}[$index]${NC} $project_name"
        echo -e "      ${CYAN}Description:${NC} ${description:0:50}..."
        echo -e "      ${CYAN}Created:${NC} $created"
        echo -e "      ${CYAN}Status:${NC} $status"
        echo ""
    done
}

# Select a project interactively
select_project() {
    list_projects

    if [ ! -d "$PROJECTS_DIR" ] || [ -z "$(ls -A "$PROJECTS_DIR" 2>/dev/null)" ]; then
        return 1
    fi

    # Build array of projects
    local projects=()
    for project_path in "$PROJECTS_DIR"/*/; do
        [ -d "$project_path" ] || continue
        projects+=("$(basename "$project_path")")
    done

    if [ ${#projects[@]} -eq 0 ]; then
        return 1
    fi

    echo -n "Select project number (1-${#projects[@]}): "
    read -r selection </dev/tty

    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#projects[@]} ]; then
        local selected_project="${projects[$((selection-1))]}"
        set_project_paths "$selected_project"
        echo "$selected_project"
        return 0
    else
        echo "Invalid selection"
        return 1
    fi
}

# Main orchestration loop
main_loop() {
    log "Starting main orchestration loop..."
    log "Press Ctrl+C to stop gracefully"
    echo ""

    local iteration=0

    while [ "$SHUTDOWN_REQUESTED" = "false" ]; do
        iteration=$((iteration + 1))

        # Show progress header
        show_progress "$iteration"

        # Step 1: Check for completed agents and review immediately
        local completed_agents=$(check_completed_agents)

        if [ -n "$completed_agents" ]; then
            log "Completed agents: $completed_agents"
            log "PM reviewing..."
            pm_review_completed "$completed_agents"

            # Merge immediately after review (don't wait)
            merge_approved_branches
        fi

        # Step 2: Check for any pending approved branches
        merge_approved_branches

        # Step 3: Check for pending tasks and dispatch
        local pending_tasks=$(get_pending_tasks)

        if [ -n "$pending_tasks" ]; then
            log "Dispatching agents for pending tasks..."
            dispatch_agents "$pending_tasks"
        fi

        # Step 4: Check if project is complete
        if is_project_complete; then
            echo ""
            log_success "═══════════════════════════════════════"
            log_success "  PROJECT COMPLETE! All tasks finished."
            log_success "═══════════════════════════════════════"
            pm_final_summary
            break
        fi

        # Step 5: Check for stuck agents
        check_stuck_agents

        # Step 6: Process any pending messages from agents
        process_pending_messages

        # Check for shutdown between operations
        if [ "$SHUTDOWN_REQUESTED" = "true" ]; then
            break
        fi

        # Wait before next cycle
        log "Next cycle in $POLL_INTERVAL seconds... (Ctrl+C to stop)"
        sleep "$POLL_INTERVAL"
    done
}

# Start a new project
start_project() {
    local project_description="$1"

    if [ -z "$project_description" ]; then
        log_error "Usage: $0 start \"Project description\""
        exit 1
    fi

    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║              STARTING NEW PROJECT                                 ║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Create new project directory (returns project name)
    local project_name=$(create_project "$project_description")

    # IMPORTANT: Re-set paths in main shell (create_project ran in subshell)
    set_project_paths "$project_name"

    echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} Created project: $project_name"

    # Initialize the project
    init_project

    log "Starting new project: $project_description"

    # Step 1: Clarify requirements with user
    log "Invoking PM to clarify requirements..."
    local enriched_description=$(pm_clarify_project "$project_description")
    log_success "Project brief saved to $STATUS_DIR/project_brief.txt"

    # Step 2: Detect external resource requirements (APIs, keys, etc.)
    log "Detecting external resource requirements..."
    pm_detect_requirements "$enriched_description"

    # Step 3: Prompt user for any required resources
    prompt_all_requirements

    # Step 4: Load collected resources into environment
    load_resources

    # Step 5: Have PM break down the project into tasks
    log "Invoking PM to plan project..."
    pm_plan_project "$enriched_description"

    # Start the main loop
    main_loop
}

# Resume existing project
resume_project() {
    local project_name="$1"

    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║              RESUME PROJECT                                       ║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # If no project specified, let user select
    if [ -z "$project_name" ]; then
        project_name=$(select_project)
        if [ $? -ne 0 ] || [ -z "$project_name" ]; then
            log_error "No project selected"
            exit 1
        fi
    fi

    # Set paths in main shell (select_project ran in subshell)
    set_project_paths "$project_name"

    if [ ! -d "$PROJECT_DIR" ]; then
        log_error "Project not found: $project_name"
        exit 1
    fi

    # Initialize the project session
    init_project

    log "Resuming project: $project_name"

    if [ -f "$STATUS_DIR/orchestrator_state.json" ]; then
        log "Found saved state, continuing from where we left off"
    fi

    if [ ! -f "$STATUS_DIR/tasks.json" ]; then
        log_warn "No tasks.json found - project may not have been planned yet"
        # Re-run planning
        local description=$(python3 -c "import json; print(json.load(open('$PROJECT_DIR/project.json')).get('description',''))" 2>/dev/null || echo "")
        if [ -n "$description" ]; then
            log "Re-planning project: $description"
            pm_plan_project "$description"
        else
            log_error "Cannot determine project description"
            exit 1
        fi
    fi

    # Load any previously saved resources
    load_resources

    # Check if there are unfulfilled requirements
    if [ -f "$STATUS_DIR/requirements.json" ]; then
        prompt_all_requirements
        load_resources
    fi

    main_loop
}

# Show status for a specific project
show_status() {
    local project_name="$1"

    # If no project specified, show list
    if [ -z "$project_name" ]; then
        list_projects
        return
    fi

    # Set paths for specified project
    set_project_paths "$project_name"

    if [ ! -d "$PROJECT_DIR" ]; then
        log_error "Project not found: $project_name"
        return 1
    fi

    echo ""
    echo -e "${BOLD}Project Status: $project_name${NC}"
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    # Show project info
    if [ -f "$PROJECT_DIR/project.json" ]; then
        local description=$(python3 -c "import json; print(json.load(open('$PROJECT_DIR/project.json')).get('description',''))" 2>/dev/null || echo "")
        echo -e "${CYAN}Description:${NC} $description"
        echo ""
    fi

    echo -e "${BOLD}Active Agents:${NC}"
    local status_files=$(ls "$STATUS_DIR"/*.status 2>/dev/null)
    if [ -n "$status_files" ]; then
        for f in $status_files; do
            local task=$(grep "task:" "$f" | cut -d: -f2 | tr -d ' ')
            local agent=$(grep "agent:" "$f" | cut -d: -f2 | tr -d ' ')
            echo "  • $task ($agent) - running"
        done
    else
        echo "  None"
    fi
    echo ""

    echo -e "${BOLD}Completed (pending merge):${NC}"
    local completed_files=$(ls "$STATUS_DIR"/*.completed "$STATUS_DIR"/*.approved 2>/dev/null)
    if [ -n "$completed_files" ]; then
        for f in $completed_files; do
            local task=$(grep "task:" "$f" | cut -d: -f2 | tr -d ' ')
            echo "  • $task"
        done
    else
        echo "  None"
    fi
    echo ""

    echo -e "${BOLD}Git Branches:${NC}"
    if [ -d "$WORKSPACE/.git" ]; then
        cd "$WORKSPACE" && git branch -a 2>/dev/null | head -10
    else
        echo "  No git repository"
    fi
    echo ""

    echo -e "${BOLD}Session Logs:${NC}"
    ls -1t "$LOGS_DIR"/session_*.log 2>/dev/null | head -3 | while read logfile; do
        echo "  • $(basename "$logfile")"
    done
    echo ""

    echo -e "${BOLD}Recent Errors:${NC}"
    if [ -f "$LOGS_DIR/errors.log" ]; then
        tail -5 "$LOGS_DIR/errors.log" 2>/dev/null || echo "  None"
    else
        echo "  None"
    fi
}

# CLI handling
case "${1:-}" in
    start)
        start_project "$2"
        ;;
    resume)
        resume_project "$2"
        ;;
    list)
        list_projects
        ;;
    status)
        show_status "$2"
        ;;
    logs)
        # Quick way to view latest session log
        if [ -n "$2" ]; then
            set_project_paths "$2"
            if [ -d "$LOGS_DIR" ]; then
                latest_log=$(ls -1t "$LOGS_DIR"/session_*.log 2>/dev/null | head -1)
                if [ -n "$latest_log" ]; then
                    less "$latest_log"
                else
                    echo "No session logs found"
                fi
            fi
        else
            echo "Usage: $0 logs <project-name>"
        fi
        ;;
    *)
        echo ""
        echo -e "${BOLD}Multi-Agent Orchestrator${NC}"
        echo ""
        echo "Usage: $0 <command> [args]"
        echo ""
        echo -e "${BOLD}Commands:${NC}"
        echo "  start \"desc\"           Start a new project"
        echo "  resume [project]        Resume a project (interactive if no name)"
        echo "  list                    List all projects"
        echo "  status [project]        Show project status (list all if no name)"
        echo "  logs <project>          View latest session log"
        echo ""
        echo -e "${BOLD}Examples:${NC}"
        echo "  $0 start \"Build a weather CLI app\""
        echo "  $0 resume"
        echo "  $0 status weather-cli_20241127_143022"
        echo ""
        echo -e "${BOLD}Project Directory:${NC}"
        echo "  $PROJECTS_DIR/"
        echo ""
        ;;
esac
