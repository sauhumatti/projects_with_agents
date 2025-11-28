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

    pending = [m for m in data.get('messages', []) if m.get('status') == 'pending']

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

    echo ""
    echo -e "${BOLD}${YELLOW}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${YELLOW}║                    PM NEEDS YOUR INPUT                                ║${NC}"
    echo -e "${BOLD}${YELLOW}╠═══════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}  Regarding: $from_agent / $task"
    echo -e "${BOLD}${YELLOW}╠═══════════════════════════════════════════════════════════════════════╣${NC}"
    echo ""
    echo -e "${CYAN}Agent's original question:${NC}"
    echo "$original_question"
    echo ""
    echo -e "${CYAN}PM asks you:${NC}"
    echo "$pm_question"
    echo ""
    echo -e "${BOLD}${YELLOW}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Play notification sound (urgent - multiple bells + system sound)
    notify_user "PM needs your input" "urgent"

    # Prompt for response
    echo "Your response (press Enter twice when done):"
    echo ""

    local response=""
    local empty_count=0
    while true; do
        read -r line </dev/tty
        if [ -z "$line" ]; then
            empty_count=$((empty_count + 1))
            if [ $empty_count -ge 2 ]; then
                break
            fi
        else
            empty_count=0
            response="$response$line"$'\n'
        fi
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
