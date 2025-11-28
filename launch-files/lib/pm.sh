#!/bin/bash
# Project Manager Functions
# Uses Claude Code as the PM brain

# Enable nullglob to handle empty glob patterns
shopt -s nullglob

# Clarify project requirements before planning
# Writes enriched description to STATUS_DIR/project_brief.txt
pm_clarify_project() {
    local project_description="$1"
    local brief_file="$STATUS_DIR/project_brief.txt"

    local prompt=$(cat <<EOF
You are a Project Manager AI. Before starting work, you need to clarify requirements.

PROJECT IDEA: $project_description

Ask 3-5 important clarifying questions to understand:
- Target platform/language
- Key features needed
- Any constraints or preferences
- Scope (MVP vs full-featured)

OUTPUT FORMAT:
List your questions numbered 1-5, one per line. Be concise.
EOF
)

    log "PM analyzing project requirements..."
    local questions=$($PM_CMD "$prompt" 2>&1)

    echo "" >&2
    echo "==========================================" >&2
    echo "PROJECT: $project_description" >&2
    echo "==========================================" >&2
    echo "" >&2
    echo "$questions" >&2
    echo "" >&2
    echo "==========================================" >&2
    echo "" >&2

    # Collect answers - read from terminal directly
    local answers=""
    echo "Please answer the questions above (press Enter twice when done):" >&2
    echo "" >&2

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
            answers="$answers$line"$'\n'
        fi
    done

    # Write enriched description to file and stdout
    cat > "$brief_file" <<BRIEF
ORIGINAL REQUEST: $project_description

CLARIFICATIONS:
$questions

USER ANSWERS:
$answers
BRIEF

    cat "$brief_file"
}

# Detect required resources for a project
# Returns JSON with required APIs, keys, services
pm_detect_requirements() {
    local project_description="$1"
    local requirements_file="$STATUS_DIR/requirements.json"

    local prompt=$(cat <<EOF
You are a Project Manager AI. Analyze this project and identify ALL external resources needed.

PROJECT: $project_description

Identify requirements such as:
- API keys (OpenAI, Stripe, SendGrid, Twilio, etc.)
- Database connections (PostgreSQL, MongoDB, Redis URLs)
- Service credentials (AWS, GCP, Firebase)
- OAuth client IDs/secrets
- Webhook URLs or endpoints
- Any other external dependencies the code will need at runtime

OUTPUT FORMAT (JSON only, no other text):
{
  "requirements": [
    {
      "name": "OPENAI_API_KEY",
      "description": "OpenAI API key for GPT integration",
      "is_secret": true,
      "required": true
    },
    {
      "name": "DATABASE_URL",
      "description": "PostgreSQL connection string",
      "is_secret": true,
      "required": true
    }
  ]
}

If NO external resources are needed, return: {"requirements": []}
Output ONLY valid JSON.
EOF
)

    log "PM detecting required resources..."
    local result=$($PM_CMD "$prompt" 2>&1)

    # Clean and extract JSON
    local cleaned=$(echo "$result" | sed 's/```json//g' | sed 's/```//g')
    echo "$cleaned" | awk '
        /\{/ { if (!started) { started=1; depth=0 } }
        started {
            print
            depth += gsub(/{/,"{") - gsub(/}/,"}")
            if (started && depth <= 0) exit
        }
    ' > "$requirements_file"

    cat "$requirements_file"
}

# Prompt user for all detected requirements
# Called after pm_detect_requirements
collect_required_resources() {
    local requirements_file="$STATUS_DIR/requirements.json"

    if [ ! -f "$requirements_file" ]; then
        return 0
    fi

    # Parse requirements and prompt for each
    python3 << PYEOF
import json
import os
import sys

requirements_file = "$requirements_file"
resources_file = "$RESOURCES_FILE"

try:
    with open(requirements_file, 'r') as f:
        data = json.load(f)

    requirements = data.get('requirements', [])
    if not requirements:
        sys.exit(0)

    # Load existing resources
    existing = {}
    if os.path.exists(resources_file):
        with open(resources_file, 'r') as f:
            for line in f:
                if '=' in line:
                    key, value = line.strip().split('=', 1)
                    existing[key] = value

    # Output requirements that need to be collected
    needed = []
    for req in requirements:
        name = req.get('name', '')
        if name and name not in existing and name not in os.environ:
            needed.append(req)

    if needed:
        # Write needed requirements to a temp file for bash to read
        with open(requirements_file + '.needed', 'w') as f:
            json.dump(needed, f)
        print(f"{len(needed)} resources needed")
    else:
        print("0 resources needed")

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

    # Check if any resources are needed
    local needed_file="$requirements_file.needed"
    if [ -f "$needed_file" ]; then
        local count=$(python3 -c "import json; print(len(json.load(open('$needed_file'))))" 2>/dev/null || echo "0")

        if [ "$count" -gt 0 ]; then
            notify_user "Project requires $count external resource(s)" "urgent"
            echo ""
            log_warn "This project requires external resources before agents can work."
            echo ""

            # Iterate through needed resources
            python3 << PYEOF2
import json

needed_file = "$needed_file"
with open(needed_file, 'r') as f:
    requirements = json.load(f)

for req in requirements:
    name = req.get('name', '')
    desc = req.get('description', name)
    is_secret = req.get('is_secret', True)
    # Output in format for bash
    secret_str = "true" if is_secret else "false"
    print(f"{name}|{desc}|{secret_str}")
PYEOF2
            # The output will be processed by bash
        fi

        rm -f "$needed_file"
    fi
}

# Interactive resource collection (called from orchestrator)
prompt_all_requirements() {
    local requirements_file="$STATUS_DIR/requirements.json"
    local needed_file="$requirements_file.needed"

    if [ ! -f "$requirements_file" ]; then
        return 0
    fi

    # Generate the needed list
    python3 << PYEOF
import json
import os

requirements_file = "$requirements_file"
resources_file = "$RESOURCES_FILE"

try:
    with open(requirements_file, 'r') as f:
        data = json.load(f)

    requirements = data.get('requirements', [])
    existing = {}

    if os.path.exists(resources_file):
        with open(resources_file, 'r') as f:
            for line in f:
                if '=' in line:
                    key, value = line.strip().split('=', 1)
                    existing[key] = value

    needed = []
    for req in requirements:
        name = req.get('name', '')
        if name and name not in existing and name not in os.environ:
            needed.append(req)

    with open("$needed_file", 'w') as f:
        json.dump(needed, f)

except Exception as e:
    with open("$needed_file", 'w') as f:
        json.dump([], f)
PYEOF

    if [ ! -f "$needed_file" ]; then
        return 0
    fi

    local count=$(python3 -c "import json; print(len(json.load(open('$needed_file'))))" 2>/dev/null || echo "0")

    if [ "$count" -eq 0 ]; then
        rm -f "$needed_file"
        return 0
    fi

    # Prompt for each resource
    while IFS='|' read -r name desc is_secret; do
        if [ -n "$name" ]; then
            prompt_for_resource "$name" "$desc" "$is_secret"
        fi
    done < <(python3 -c "
import json
with open('$needed_file', 'r') as f:
    for req in json.load(f):
        name = req.get('name', '')
        desc = req.get('description', name)
        secret = 'true' if req.get('is_secret', True) else 'false'
        print(f'{name}|{desc}|{secret}')
")

    rm -f "$needed_file"
    log_success "All required resources collected"
}

# Plan a new project - breaks it down into tasks
pm_plan_project() {
    local project_description="$1"
    local tasks_file="$STATUS_DIR/tasks.json"
    local branches_info=""

    cd "$WORKSPACE"
    branches_info=$(git branch -a 2>/dev/null || echo "No branches yet")
    cd "$SCRIPT_DIR"

    local prompt=$(cat <<EOF
You are a Project Manager AI coordinating multiple AI coding agents.

PROJECT: $project_description

WORKSPACE: $WORKSPACE

AVAILABLE AGENTS & CAPABILITIES:

1. CLAUDE (claude) - THE RESEARCHER & ARCHITECT
   - Best at: Research, architecture decisions, complex logic, API integrations
   - MCP Tools: Chrome DevTools (browser automation, screenshots, console logs)
   - Web search: YES
   - Strengths: Thorough, reliable, excellent at reading documentation
   - Use for: Researching libraries, reading API docs, architecture decisions, backend logic

2. CODEX (codex) - THE CODE GENERATOR
   - Best at: Fast code generation, refactoring, boilerplate
   - MCP Tools: Chrome DevTools (browser automation)
   - Web search: NO
   - Strengths: Fast, efficient, good at patterns
   - Use for: Writing code when specs are clear, UI components, utility functions
   - Note: Needs clear specs - cannot research on its own

3. GEMINI (gemini) - THE VISUAL TESTER & QA
   - Best at: Visual reasoning, UI testing, creative solutions
   - MCP Tools: Chrome DevTools (browser automation, screenshots, console logs)
   - Web search: YES
   - Strengths: Great visual reasoning, can verify UI looks correct
   - Use for: Visual QA, testing UI flows, verifying layouts, E2E testing

═══════════════════════════════════════════════════════════════════════════════
                         DEPENDENCY-BASED TASK PLANNING
═══════════════════════════════════════════════════════════════════════════════

Create a task graph where each task specifies its dependencies. Tasks with no
pending dependencies run in parallel. YOU decide the optimal order based on
the project's actual needs - there are NO rigid phases.

TASK TYPES (use as needed, mix freely):

• RESEARCH - Gather information before implementing
  - Output: docs/*.md files with findings
  - Assign to: Claude or Gemini (NOT Codex - no web access)

• SETUP - Initialize project structure, install dependencies
  - Usually depends on relevant research
  - Assign to: Claude (most reliable)

• IMPLEMENT - Build features and components
  - Depends on: setup tasks and/or other implementations
  - Assign to: Any agent based on complexity

• TEST - Verify functionality works correctly
  - Depends on: the implementation it tests
  - Assign to: Gemini (visual) or Claude (integration)

• INTEGRATE - Combine multiple features, final assembly
  - Depends on: all features being integrated
  - Assign to: Claude

DEPENDENCY RULES:
1. Tasks with depends_on: [] run immediately (in parallel)
2. A task runs when ALL its dependencies are complete
3. Use dependencies to express ACTUAL requirements, not artificial phases
4. Maximize parallelism - only add dependencies where truly needed

EXAMPLE PATTERNS:

Pattern A: Research then implement (common)
  research-auth ──┬──► setup-project ──► implement-auth
  research-ui ────┘

Pattern B: Parallel features after setup
  setup ──┬──► feature-A ──┐
          ├──► feature-B ──┼──► integration
          └──► feature-C ──┘

Pattern C: Interleaved research and implementation
  research-api ──► implement-api ──► research-webhooks ──► implement-webhooks

Pattern D: Test after implement
  implement-login ──► test-login ──┐
  implement-signup ──► test-signup ──┼──► test-e2e
  implement-dashboard ──────────────┘

OUTPUT FORMAT (JSON only, no other text):
{
  "project_name": "short-name",
  "tasks": [
    {
      "id": "task-1",
      "type": "research",
      "branch": "research/frameworks",
      "agent": "claude",
      "description": "Research best frameworks for [X]. Check official docs. Output findings to docs/frameworks.md.",
      "depends_on": []
    },
    {
      "id": "task-2",
      "type": "setup",
      "branch": "setup/project",
      "agent": "claude",
      "description": "Initialize project with [framework]. Install dependencies. Create folder structure.",
      "depends_on": ["task-1"]
    },
    {
      "id": "task-3",
      "type": "implement",
      "branch": "feature/user-auth",
      "agent": "codex",
      "description": "Implement user authentication following patterns from docs/frameworks.md.",
      "depends_on": ["task-2"]
    },
    {
      "id": "task-4",
      "type": "implement",
      "branch": "feature/dashboard",
      "agent": "codex",
      "description": "Implement dashboard UI component.",
      "depends_on": ["task-2"]
    },
    {
      "id": "task-5",
      "type": "test",
      "branch": "test/auth-flow",
      "agent": "gemini",
      "description": "Test the authentication flow. Start dev server, navigate through login/signup, verify it works.",
      "depends_on": ["task-3"]
    },
    {
      "id": "task-6",
      "type": "integrate",
      "branch": "feature/integration",
      "agent": "claude",
      "description": "Integrate all features, ensure they work together, fix any integration issues.",
      "depends_on": ["task-3", "task-4", "task-5"]
    }
  ]
}

IMPORTANT:
- Every task MUST have "depends_on" (use [] for no dependencies)
- Be specific in descriptions - agents work independently
- Use meaningful branch names reflecting the work
- Maximize parallelism where tasks are truly independent

Output ONLY the JSON, nothing else.
EOF
)

    log "PM planning project..."
    local result=$($PM_CMD "$prompt" 2>&1)

    # Save raw result for debugging
    echo "$result" > "$LOGS_DIR/pm_plan_raw.log"

    # Strip markdown code fences and extract JSON
    local cleaned=$(echo "$result" | sed 's/```json//g' | sed 's/```//g')

    # Extract JSON block from { to }
    echo "$cleaned" | awk '
        /\{/ { if (!started) { started=1; depth=0 } }
        started {
            print
            depth += gsub(/{/,"{") - gsub(/}/,"}")
            if (started && depth <= 0) exit
        }
    ' > "$tasks_file"

    log_success "Project plan created: $tasks_file"
    cat "$tasks_file"
    echo ""
}

# Review completed agent work
# PM only decides APPROVE/REJECT - merging is handled separately
pm_review_completed() {
    local completed_agents="$1"

    cd "$WORKSPACE"

    for status_file in $STATUS_DIR/*.completed; do
        [ -f "$status_file" ] || continue

        local agent_id=$(basename "$status_file" .completed)
        local branch=$(cat "$status_file" | grep "branch:" | cut -d: -f2 | tr -d ' ')
        local task_id=$(cat "$status_file" | grep "task:" | cut -d: -f2 | tr -d ' ')

        log "Reviewing work from $agent_id on branch $branch..."

        # Get the diff for this branch
        local diff=$(git diff main...$branch 2>/dev/null | head -200 || echo "No diff available")
        local files=$(git diff --name-only main...$branch 2>/dev/null || echo "No files")

        local prompt=$(cat <<EOF
You are a Project Manager reviewing completed work from an AI agent.

TASK ID: $task_id
BRANCH: $branch

FILES CHANGED:
$files

DIFF (truncated):
$diff

Quick review - decide:
- APPROVE: Work looks reasonable, has code, accomplishes the task
- REJECT: No meaningful work done, empty, or completely wrong approach

Be lenient - approve if there's genuine effort and code. Minor issues can be fixed later.

OUTPUT FORMAT (JSON only):
{
  "decision": "APPROVE|REJECT",
  "reason": "brief explanation (1 sentence)"
}
EOF
)

        local review=$($PM_CMD "$prompt" 2>/dev/null)
        echo "$review" > "$STATUS_DIR/${agent_id}.review"

        # Parse decision
        local decision=$(echo "$review" | grep -o '"decision"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)

        case "$decision" in
            APPROVE)
                log_success "PM approved $branch"
                # Mark as approved - merge will be handled separately
                mv "$status_file" "${status_file%.completed}.approved"
                ;;
            REJECT)
                log_error "PM rejected $branch"
                rm -f "$status_file"
                mark_task_failed "$task_id"
                ;;
            *)
                # Default to approve if unclear
                log_warn "PM decision unclear, defaulting to approve"
                mv "$status_file" "${status_file%.completed}.approved"
                ;;
        esac
    done

    cd "$LAUNCH_DIR"
}

# Merge approved branches to main
# Spawns conflict resolution agent if needed
merge_approved_branches() {
    cd "$WORKSPACE"
    git checkout main 2>/dev/null || git checkout master 2>/dev/null

    for approved_file in $STATUS_DIR/*.approved; do
        [ -f "$approved_file" ] || continue

        local task_id=$(cat "$approved_file" | grep "task:" | cut -d: -f2 | tr -d ' ')
        local branch=$(cat "$approved_file" | grep "branch:" | cut -d: -f2 | tr -d ' ')

        # Skip if task_id or branch is empty (malformed .approved file)
        if [ -z "$task_id" ] || [ -z "$branch" ]; then
            log_warn "Skipping malformed .approved file: $approved_file (missing task or branch)"
            # Clean up the malformed file to prevent infinite loop
            rm -f "$approved_file"
            continue
        fi

        log "Attempting to merge $branch to main..."

        # Try the merge
        if git merge "$branch" -m "Merge $branch (task $task_id)" 2>/dev/null; then
            log_success "Merged $branch successfully"
            rm -f "$approved_file"
            rm -f "$STATUS_DIR/${task_id}.conflict_retries"
            mark_task_complete "$task_id"
        else
            # Merge conflict - check retry count
            git merge --abort 2>/dev/null

            local retry_file="$STATUS_DIR/${task_id}.conflict_retries"
            local retries=0
            if [ -f "$retry_file" ]; then
                retries=$(cat "$retry_file")
            fi
            retries=$((retries + 1))
            echo "$retries" > "$retry_file"

            if [ "$retries" -gt "${MAX_CONFLICT_RETRIES:-2}" ]; then
                log_error "Merge conflict on $branch - max retries ($MAX_CONFLICT_RETRIES) exceeded"
                log_warn "Marking $task_id for human review"
                mv "$approved_file" "${approved_file%.approved}.needs_human_review"
                rm -f "$retry_file"
            else
                log_warn "Merge conflict on $branch - spawning resolution agent (attempt $retries/$MAX_CONFLICT_RETRIES)"
                resolve_merge_conflict "$task_id" "$branch"
            fi
        fi
    done

    cd "$LAUNCH_DIR"
}

# Spawn an agent to resolve merge conflicts
resolve_merge_conflict() {
    local task_id="$1"
    local branch="$2"
    local conflict_workspace="$AGENTS_DIR/conflict-${task_id}"

    log "Setting up conflict resolution for $branch..."

    # Clone fresh workspace
    rm -rf "$conflict_workspace"
    git clone "$WORKSPACE" "$conflict_workspace" 2>/dev/null

    cd "$conflict_workspace"
    git checkout main 2>/dev/null

    # Start merge (will have conflicts)
    git merge "$branch" --no-commit 2>/dev/null || true

    local conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null)

    local prompt="You are resolving a git merge conflict.
BRANCH being merged: $branch
CONFLICTING FILES: $conflict_files

Instructions:
1. Read each conflicting file to understand both versions
2. Resolve conflicts by intelligently combining both versions
3. Remove ALL conflict markers (<<<<<<<, =======, >>>>>>>)
4. Stage resolved files: git add <file>
5. Commit the merge: git commit -m 'Resolve merge conflict for $branch'

Be thorough - check that no conflict markers remain."

    # Use Claude for conflict resolution (most reliable)
    log "Running conflict resolution agent..."
    $CLAUDE_CMD "$prompt" 2>&1 > "$LOGS_DIR/conflict-${task_id}.log"

    # Check if merge was completed successfully
    local remaining_conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null)

    if [ -z "$remaining_conflicts" ]; then
        # Check for uncommitted changes
        if [ -n "$(git status --porcelain)" ]; then
            git add -A
            git commit -m "Resolve merge conflict for $branch" 2>/dev/null || true
        fi

        # Push resolved changes back to main workspace
        log "Pushing resolved merge to main workspace..."
        cd "$WORKSPACE"
        git fetch "$conflict_workspace" main:main 2>/dev/null || {
            git pull "$conflict_workspace" main 2>/dev/null || true
        }

        log_success "Conflict resolved for $branch"
        rm -f "$STATUS_DIR/${task_id}.approved"
        rm -f "$STATUS_DIR/${task_id}.conflict_retries"
        mark_task_complete "$task_id"
    else
        log_warn "Conflict resolution incomplete - $remaining_conflicts still have conflicts"
        # Don't mark as failed - let retry logic handle it
    fi

    cd "$LAUNCH_DIR"
}

# Generate final project summary
pm_final_summary() {
    cd "$WORKSPACE"

    local prompt=$(cat <<EOF
You are a Project Manager. The project is complete.

Generate a brief summary of what was accomplished.

GIT LOG:
$(git log --oneline -20)

FILES IN PROJECT:
$(find . -type f -not -path './.git/*' | head -50)

Provide a concise summary of the completed project.
EOF
)

    log "Generating final summary..."
    $PM_CMD "$prompt"
    cd "$SCRIPT_DIR"
}

# Mark a task as complete
mark_task_complete() {
    local task_id="$1"
    local tasks_file="$STATUS_DIR/tasks.json"

    if [ -f "$tasks_file" ]; then
        # Update task status in JSON (using simple sed for now)
        sed -i "s/\"id\": \"$task_id\"/\"id\": \"$task_id\", \"status\": \"completed\"/" "$tasks_file"
    fi
}

# Mark a task as failed
mark_task_failed() {
    local task_id="$1"
    local tasks_file="$STATUS_DIR/tasks.json"

    if [ -f "$tasks_file" ]; then
        sed -i "s/\"id\": \"$task_id\"/\"id\": \"$task_id\", \"status\": \"failed\"/" "$tasks_file"
    fi
}
