#!/bin/bash
# Message Handling Functions
# Routes messages between agents, PM, and user

# Enable nullglob to handle empty glob patterns
shopt -s nullglob

# Initialize messaging system for a project
init_messaging() {
    local messages_dir="$STATUS_DIR/messages"
    mkdir -p "$messages_dir"

    # Initialize empty message files if they don't exist
    [ -f "$messages_dir/outbox.json" ] || echo '{"messages":[]}' > "$messages_dir/outbox.json"
    [ -f "$messages_dir/inbox.json" ] || echo '{"messages":[]}' > "$messages_dir/inbox.json"
    [ -f "$messages_dir/status.json" ] || echo '{"agents":{}}' > "$messages_dir/status.json"

    # Initialize agent pool files
    [ -f "$messages_dir/agent_pool.json" ] || echo '{"agents":{}}' > "$messages_dir/agent_pool.json"
    [ -f "$messages_dir/assignments.json" ] || echo '{"pending":[],"accepted":[],"completed":[]}' > "$messages_dir/assignments.json"

    log "Messaging system initialized"
}

# Check for pending messages from agents
check_agent_messages() {
    local messages_dir="$STATUS_DIR/messages"
    local outbox="$messages_dir/outbox.json"

    [ -f "$outbox" ] || return 0

    # Get pending messages using Python
    python3 << PYEOF
import json
import os

outbox_file = "$outbox"

try:
    with open(outbox_file, 'r') as f:
        data = json.load(f)

    # Get pending messages, excluding task_complete (handled by process_task_completions)
    pending = [m for m in data.get('messages', [])
               if m.get('status') == 'pending' and m.get('type') != 'task_complete']

    for msg in pending:
        msg_id = msg.get('id', '')
        to = msg.get('to', '')
        from_agent = msg.get('from', '')
        task = msg.get('task', '')
        question = msg.get('question', msg.get('message', ''))
        priority = msg.get('priority', 'normal')
        msg_type = msg.get('type', 'question')

        # Output in format for bash to parse
        print(f"{msg_id}|{to}|{from_agent}|{task}|{priority}|{msg_type}|{question}")

except Exception as e:
    pass
PYEOF
}

# Process a single message (route to PM or user)
process_message() {
    local msg_id="$1"
    local to="$2"
    local from_agent="$3"
    local task="$4"
    local priority="$5"
    local msg_type="$6"
    local question="$7"

    local messages_dir="$STATUS_DIR/messages"

    # Mark message as processing
    update_message_status "$msg_id" "processing"

    case "$to" in
        pm)
            if [ "$msg_type" = "notification" ]; then
                # Just log notifications, don't need response
                log "[PM Notification from $from_agent] $question"
                update_message_status "$msg_id" "delivered"
            else
                # Route to PM for response (PM may escalate to user if needed)
                handle_pm_message "$msg_id" "$from_agent" "$task" "$question" "$priority"
            fi
            ;;
        *)
            # Agents can only message PM - reject other recipients
            log_warn "Agent tried to message '$to' directly - only PM allowed"
            update_message_status "$msg_id" "rejected"
            ;;
    esac
}

# Handle a message directed to PM
handle_pm_message() {
    local msg_id="$1"
    local from_agent="$2"
    local task="$3"
    local question="$4"
    local priority="$5"

    log "PM received question from $from_agent (task: $task)"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  AGENT MESSAGE${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo "  From: $from_agent"
    echo "  Task: $task"
    echo "  Priority: $priority"
    echo ""
    echo "$question"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"

    # Let PM (Claude) analyze and decide how to respond
    local pm_prompt="You are a Project Manager. An agent on your team has a question.

AGENT: $from_agent
TASK: $task
PRIORITY: $priority

QUESTION FROM AGENT:
$question

You have two options:
1. ANSWER DIRECTLY - If you can answer based on project context and your judgment
2. ESCALATE TO USER - If this requires human decision (preferences, business logic, approval for significant changes)

Respond in this exact format:
ACTION: ANSWER or ESCALATE
RESPONSE: Your answer to the agent, OR the question to ask the user

Be decisive. Only escalate if truly necessary (user preferences, business decisions, unclear requirements).
Most technical questions you should answer yourself."

    log "PM analyzing question..."
    local pm_analysis=$($PM_CMD "$pm_prompt" 2>&1)

    # Parse the PM's decision
    local action=$(echo "$pm_analysis" | grep -i "^ACTION:" | head -1 | sed 's/ACTION:[[:space:]]*//' | tr '[:lower:]' '[:upper:]')
    local response=$(echo "$pm_analysis" | sed -n '/^RESPONSE:/,$ p' | sed 's/^RESPONSE:[[:space:]]*//')

    # Default to answer if parsing fails
    if [ -z "$action" ]; then
        action="ANSWER"
        response="$pm_analysis"
    fi

    case "$action" in
        *ESCALATE*)
            log_warn "PM escalating to user..."
            echo ""

            # Get user input
            local user_response=$(escalate_to_user "$from_agent" "$task" "$question" "$response")

            # PM formulates final response incorporating user input
            local final_prompt="You are a Project Manager. You asked the user for input and received their response.

ORIGINAL AGENT QUESTION:
$question

USER'S RESPONSE:
$user_response

Now provide a clear, actionable response to the agent that incorporates the user's input.
Be specific and direct. Just give the answer, no preamble."

            local final_response=$($PM_CMD "$final_prompt" 2>&1)
            send_response "$msg_id" "pm" "$final_response"
            log_success "PM responded to $from_agent (with user input)"
            ;;
        *)
            # PM answers directly
            send_response "$msg_id" "pm" "$response"
            log_success "PM responded to $from_agent"
            ;;
    esac
}

# Escalate a question to the user (called by PM only)
escalate_to_user() {
    local from_agent="$1"
    local task="$2"
    local original_question="$3"
    local pm_question="$4"
    local timeout_seconds=120  # 2 minute timeout

    # Clear some space and make it VERY visible
    echo ""
    echo ""
    echo ""
    echo -e "${BOLD}${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
    echo -e "${BOLD}${YELLOW}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${YELLOW}║                    PM NEEDS YOUR INPUT                                ║${NC}"
    echo -e "${BOLD}${YELLOW}╠═══════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}  Regarding: ${BOLD}$from_agent${NC} / ${BOLD}$task${NC}"
    echo -e "${BOLD}${YELLOW}╠═══════════════════════════════════════════════════════════════════════╣${NC}"
    echo ""
    echo -e "${CYAN}Agent's original question:${NC}"
    echo "$original_question" | head -10
    echo ""
    echo -e "${CYAN}PM asks you:${NC}"
    echo "$pm_question" | head -10
    echo ""
    echo -e "${BOLD}${YELLOW}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${BOLD}${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
    echo ""

    # Play notification sound (urgent - multiple beeps)
    notify_user "PM needs your input" "urgent"

    # Prompt for response with timeout
    echo -e "${BOLD}Your response (Enter twice to submit, or wait ${timeout_seconds}s for auto-skip):${NC}"
    echo ""

    local response=""
    local empty_count=0
    local start_time=$(date +%s)

    while true; do
        local now=$(date +%s)
        local elapsed=$((now - start_time))

        if [ $elapsed -ge $timeout_seconds ]; then
            echo ""
            echo -e "${YELLOW}[Timeout - PM will proceed with best judgment]${NC}"
            response="[USER TIMEOUT - No response provided within ${timeout_seconds} seconds. Please proceed with your best judgment.]"
            break
        fi

        # Read with 5 second timeout per line
        if read -t 5 -r line </dev/tty 2>/dev/null; then
            if [ -z "$line" ]; then
                empty_count=$((empty_count + 1))
                if [ $empty_count -ge 2 ]; then
                    break
                fi
            else
                empty_count=0
                response="$response$line"$'\n'
            fi
        fi
        # If read times out, loop continues and checks overall timeout
    done

    echo "$response"
}


# Send a response to the inbox
send_response() {
    local reply_to="$1"
    local from="$2"
    local answer="$3"

    local messages_dir="$STATUS_DIR/messages"
    local inbox="$messages_dir/inbox.json"

    python3 << PYEOF
import json
import os
from datetime import datetime
import uuid

inbox_file = "$inbox"
reply_to = "$reply_to"
from_sender = "$from"
answer = '''$answer'''

try:
    # Read existing inbox
    if os.path.exists(inbox_file):
        with open(inbox_file, 'r') as f:
            data = json.load(f)
    else:
        data = {"messages": []}

    # Add response
    data['messages'].append({
        "id": str(uuid.uuid4()),
        "replyTo": reply_to,
        "from": from_sender,
        "answer": answer.strip(),
        "timestamp": datetime.now().isoformat(),
        "read": False
    })

    # Write atomically
    tmp_file = inbox_file + ".tmp"
    with open(tmp_file, 'w') as f:
        json.dump(data, f, indent=2)
    os.rename(tmp_file, inbox_file)

except Exception as e:
    print(f"Error sending response: {e}", file=__import__('sys').stderr)
PYEOF

    # Update original message status
    update_message_status "$reply_to" "responded"
}

# Update message status in outbox
update_message_status() {
    local msg_id="$1"
    local new_status="$2"

    local messages_dir="$STATUS_DIR/messages"
    local outbox="$messages_dir/outbox.json"

    python3 << PYEOF
import json
import os

outbox_file = "$outbox"
msg_id = "$msg_id"
new_status = "$new_status"

try:
    with open(outbox_file, 'r') as f:
        data = json.load(f)

    for msg in data.get('messages', []):
        if msg.get('id') == msg_id:
            msg['status'] = new_status
            break

    tmp_file = outbox_file + ".tmp"
    with open(tmp_file, 'w') as f:
        json.dump(data, f, indent=2)
    os.rename(tmp_file, outbox_file)

except Exception as e:
    pass
PYEOF
}

# Main message processing loop (called from orchestrator main loop)
process_pending_messages() {
    local messages_dir="$STATUS_DIR/messages"

    [ -d "$messages_dir" ] || return 0

    # Check for pending messages
    local pending_messages=$(check_agent_messages)

    [ -z "$pending_messages" ] && return 0

    # Process each message
    while IFS='|' read -r msg_id to from_agent task priority msg_type question; do
        [ -z "$msg_id" ] && continue

        process_message "$msg_id" "$to" "$from_agent" "$task" "$priority" "$msg_type" "$question"
    done <<< "$pending_messages"
}

# Get agent status summary
get_agent_status_summary() {
    local messages_dir="$STATUS_DIR/messages"
    local status_file="$messages_dir/status.json"

    [ -f "$status_file" ] || return 0

    python3 << PYEOF
import json

status_file = "$status_file"

try:
    with open(status_file, 'r') as f:
        data = json.load(f)

    agents = data.get('agents', {})
    if not agents:
        print("No agent status updates")
        exit(0)

    for agent_id, info in agents.items():
        status = info.get('status', 'unknown')
        details = info.get('details', {})
        message = details.get('message', '')
        progress = details.get('progress', '')

        progress_str = f" [{progress}%]" if progress else ""
        message_str = f" - {message}" if message else ""

        print(f"  {agent_id}: {status}{progress_str}{message_str}")

except Exception as e:
    pass
PYEOF
}

# Show pending messages waiting for response
show_pending_messages() {
    local messages_dir="$STATUS_DIR/messages"
    local outbox="$messages_dir/outbox.json"

    [ -f "$outbox" ] || return 0

    python3 << PYEOF
import json

outbox_file = "$outbox"

try:
    with open(outbox_file, 'r') as f:
        data = json.load(f)

    pending = [m for m in data.get('messages', []) if m.get('status') == 'pending']

    if pending:
        print(f"  {len(pending)} message(s) waiting for response")
        for msg in pending[:3]:  # Show first 3
            to = msg.get('to', 'unknown')
            from_agent = msg.get('from', 'unknown')
            preview = msg.get('question', msg.get('message', ''))[:50]
            print(f"    - [{to}] from {from_agent}: {preview}...")

except Exception as e:
    pass
PYEOF
}

# ============================================================================
# AGENT POOL MANAGEMENT (PM Tools)
# ============================================================================

# List all agents in the pool with their status
list_agent_pool() {
    local messages_dir="$STATUS_DIR/messages"
    local pool_file="$messages_dir/agent_pool.json"

    [ -f "$pool_file" ] || { echo "No agents in pool"; return 0; }

    python3 << PYEOF
import json
from datetime import datetime

pool_file = "$pool_file"

try:
    with open(pool_file, 'r') as f:
        data = json.load(f)

    agents = data.get('agents', {})
    if not agents:
        print("No agents registered in pool")
        exit(0)

    # Group by status
    active = []
    standby = []
    completed = []
    terminated = []

    for agent_id, info in agents.items():
        status = info.get('status', 'unknown')
        role = info.get('role', 'unknown')
        capabilities = ', '.join(info.get('capabilities', []))
        current_task = info.get('currentTask', 'none')
        last_seen = info.get('lastSeen', '')

        agent_info = {
            'id': agent_id,
            'role': role,
            'capabilities': capabilities,
            'task': current_task,
            'lastSeen': last_seen
        }

        if status == 'active':
            active.append(agent_info)
        elif status == 'standby':
            standby.append(agent_info)
        elif status == 'completed':
            completed.append(agent_info)
        else:
            terminated.append(agent_info)

    # Print summary
    print(f"Agent Pool Status:")
    print(f"  Active: {len(active)}  |  Standby: {len(standby)}  |  Completed: {len(completed)}  |  Terminated: {len(terminated)}")
    print("")

    if standby:
        print("AVAILABLE FOR WORK:")
        for a in standby:
            print(f"  [{a['id']}] role={a['role']} caps=[{a['capabilities']}]")
        print("")

    if active:
        print("CURRENTLY WORKING:")
        for a in active:
            print(f"  [{a['id']}] working on: {a['task']}")
        print("")

except Exception as e:
    print(f"Error reading pool: {e}")
PYEOF
}

# Get list of standby agents (for PM decision making)
get_standby_agents() {
    local messages_dir="$STATUS_DIR/messages"
    local pool_file="$messages_dir/agent_pool.json"

    [ -f "$pool_file" ] || return 0

    python3 << PYEOF
import json

pool_file = "$pool_file"

try:
    with open(pool_file, 'r') as f:
        data = json.load(f)

    for agent_id, info in data.get('agents', {}).items():
        if info.get('status') == 'standby':
            role = info.get('role', '')
            capabilities = ','.join(info.get('capabilities', []))
            print(f"{agent_id}|{role}|{capabilities}")

except Exception as e:
    pass
PYEOF
}

# Assign a task to a waiting agent
assign_task_to_agent() {
    local agent_id="$1"
    local task_id="$2"
    local branch="$3"
    local task_type="$4"
    local description="$5"

    local messages_dir="$STATUS_DIR/messages"
    local assignments_file="$messages_dir/assignments.json"
    local pool_file="$messages_dir/agent_pool.json"

    python3 << PYEOF
import json
import uuid
from datetime import datetime
import os

assignments_file = "$assignments_file"
pool_file = "$pool_file"
agent_id = "$agent_id"
task_id = "$task_id"
branch = "$branch"
task_type = "$task_type"
description = '''$description'''

try:
    # Read existing assignments
    if os.path.exists(assignments_file):
        with open(assignments_file, 'r') as f:
            data = json.load(f)
    else:
        data = {"pending": [], "accepted": [], "completed": []}

    # Create new assignment
    assignment = {
        "id": str(uuid.uuid4()),
        "agentId": agent_id,
        "taskId": task_id,
        "branch": branch,
        "type": task_type,
        "description": description.strip(),
        "assignedAt": datetime.now().isoformat()
    }

    data['pending'] = data.get('pending', [])
    data['pending'].append(assignment)

    # Write atomically
    tmp_file = assignments_file + ".tmp"
    with open(tmp_file, 'w') as f:
        json.dump(data, f, indent=2)
    os.rename(tmp_file, assignments_file)

    # Also update agent pool status to 'assigned' so it's not picked again
    if os.path.exists(pool_file):
        with open(pool_file, 'r') as f:
            pool = json.load(f)

        if 'agents' in pool and agent_id in pool['agents']:
            pool['agents'][agent_id]['status'] = 'assigned'
            pool['agents'][agent_id]['currentTask'] = task_id
            pool['agents'][agent_id]['lastSeen'] = datetime.now().isoformat()

            tmp_file = pool_file + ".tmp"
            with open(tmp_file, 'w') as f:
                json.dump(pool, f, indent=2)
            os.rename(tmp_file, pool_file)

    print(f"Assignment created: {task_id} -> {agent_id}")

except Exception as e:
    print(f"Error: {e}", file=__import__('sys').stderr)
PYEOF

    log "Assigned task $task_id to waiting agent $agent_id"
}

# Check for completed tasks and process them
# Returns JSON array for robust parsing
check_task_completions() {
    local messages_dir="$STATUS_DIR/messages"
    local outbox="$messages_dir/outbox.json"

    [ -f "$outbox" ] || return 0

    # Look for task_complete messages - output as JSON for safe parsing
    python3 << PYEOF
import json

outbox_file = "$outbox"

try:
    with open(outbox_file, 'r') as f:
        data = json.load(f)

    completions = [m for m in data.get('messages', [])
                   if m.get('type') == 'task_complete' and m.get('status') == 'pending']

    if completions:
        # Output as JSON array for robust parsing
        output = []
        for msg in completions:
            output.append({
                'id': msg.get('id', ''),
                'agent': msg.get('from', ''),
                'task': msg.get('task', ''),
                'summary': msg.get('summary', ''),
                'files': msg.get('filesChanged', [])
            })
        print(json.dumps(output))

except Exception as e:
    pass
PYEOF
}

# Process a task completion (mark message as handled, update status)
handle_task_completion() {
    local msg_id="$1"
    local agent_id="$2"
    local task_id="$3"
    local summary="$4"

    log_success "Agent $agent_id completed: $summary"

    # Mark message as handled
    update_message_status "$msg_id" "handled"

    # Could trigger follow-up actions here (e.g., run tests, code review)
}

# Try to assign a pending task to an available agent
try_assign_to_pool() {
    local task_id="$1"
    local branch="$2"
    local task_type="$3"
    local description="$4"
    local preferred_capabilities="$5"

    # Get standby agents
    local standby_agents=$(get_standby_agents)

    [ -z "$standby_agents" ] && return 1  # No available agents

    # Find a matching agent (simple matching for now)
    local best_agent=""
    while IFS='|' read -r agent_id role capabilities; do
        [ -z "$agent_id" ] && continue

        # If we need specific capabilities, check for match
        if [ -n "$preferred_capabilities" ]; then
            if echo "$capabilities" | grep -qi "$preferred_capabilities"; then
                best_agent="$agent_id"
                break
            fi
        else
            # Any available agent
            best_agent="$agent_id"
            break
        fi
    done <<< "$standby_agents"

    if [ -n "$best_agent" ]; then
        assign_task_to_agent "$best_agent" "$task_id" "$branch" "$task_type" "$description"
        return 0
    fi

    return 1  # No matching agent found
}

# Display agent pool status (for progress display)
show_agent_pool_status() {
    local messages_dir="$STATUS_DIR/messages"
    local pool_file="$messages_dir/agent_pool.json"

    [ -f "$pool_file" ] || return 0

    python3 << PYEOF
import json

pool_file = "$pool_file"

try:
    with open(pool_file, 'r') as f:
        data = json.load(f)

    agents = data.get('agents', {})
    if not agents:
        exit(0)

    active = sum(1 for a in agents.values() if a.get('status') == 'active')
    standby = sum(1 for a in agents.values() if a.get('status') == 'standby')

    if active > 0 or standby > 0:
        print(f"  Pool: {active} active, {standby} standby")

except Exception as e:
    pass
PYEOF
}
