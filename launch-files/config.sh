#!/bin/bash
# Orchestrator Configuration

# Base directories
export LAUNCH_DIR="/home/sauhumatti/gemini/launch-files"
export RUNTIME_DIR="/home/sauhumatti/gemini/runtime"
export PROJECTS_DIR="$RUNTIME_DIR/projects"

# Active project directory (set by orchestrator when starting/resuming)
export PROJECT_DIR=""        # e.g., runtime/projects/weather-cli_20241127_143022
export WORKSPACE=""          # e.g., PROJECT_DIR/workspace
export AGENTS_DIR=""         # e.g., PROJECT_DIR/agents
export STATUS_DIR=""         # e.g., PROJECT_DIR/status
export LOGS_DIR=""           # e.g., PROJECT_DIR/logs
export RESOURCES_FILE=""     # e.g., PROJECT_DIR/status/resources.env

# MCP Configurations (unified chrome-devtools for all agents)
export MCP_DIR="$LAUNCH_DIR/mcp"
export CHROME_DEVTOOLS_MCP_CONFIG="$MCP_DIR/chrome-devtools-mcp.json"
export PM_MCP_CONFIG=""  # Generated dynamically per project

# Agent configurations (all agents use chrome-devtools MCP in headless mode)
# NOTE: MCP must be set up globally for each agent before running:
#   claude mcp add chrome-devtools npx chrome-devtools-mcp@latest
#   codex mcp add chrome-devtools -- npx chrome-devtools-mcp@latest
#   gemini mcp add -s user chrome-devtools npx chrome-devtools-mcp@latest
#
# Claude: Chrome DevTools MCP for browser automation
export CLAUDE_CMD="claude -p --dangerously-skip-permissions --mcp-config=$CHROME_DEVTOOLS_MCP_CONFIG"
# Codex: Chrome DevTools MCP (uses global config from .codex/config.toml)
export CODEX_CMD="codex exec --skip-git-repo-check --full-auto"
# Gemini: Chrome DevTools MCP (uses global config from .gemini/settings.json)
export GEMINI_CMD="gemini -y"

# PM Configuration (uses Claude Code as the PM)
# PM_CMD is set dynamically after project paths are configured
export PM_CMD=""

# Generate PM MCP config with agent control tools
# Must be defined before set_project_paths which calls it
generate_pm_mcp_config() {
    local config_file="$STATUS_DIR/pm-mcp-config.json"

    cat > "$config_file" << MCPEOF
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["chrome-devtools-mcp@latest"],
      "env": {
        "CHROME_HEADLESS": "true"
      }
    },
    "pm-control": {
      "command": "node",
      "args": ["$LAUNCH_DIR/mcp/pm-control-server/server.js"],
      "env": {
        "STATUS_DIR": "$STATUS_DIR",
        "AGENTS_DIR": "$AGENTS_DIR",
        "WORKSPACE": "$WORKSPACE"
      }
    },
    "messaging": {
      "command": "node",
      "args": ["$LAUNCH_DIR/mcp/messaging-server/server.js"],
      "env": {
        "ORCHESTRATOR_MESSAGES_DIR": "$STATUS_DIR/messages",
        "ORCHESTRATOR_AGENT_ID": "pm",
        "ORCHESTRATOR_TASK_ID": "orchestration"
      }
    }
  }
}
MCPEOF

    export PM_MCP_CONFIG="$config_file"
    export PM_CMD="claude -p --dangerously-skip-permissions --mcp-config=$config_file"
}

# Function to set project paths (called when project is selected)
set_project_paths() {
    local project_name="$1"
    export PROJECT_DIR="$PROJECTS_DIR/$project_name"
    export WORKSPACE="$PROJECT_DIR/workspace"
    export AGENTS_DIR="$PROJECT_DIR/agents"
    export STATUS_DIR="$PROJECT_DIR/status"
    export LOGS_DIR="$PROJECT_DIR/logs"
    export RESOURCES_FILE="$STATUS_DIR/resources.env"

    # Generate PM MCP config if status dir exists
    if [ -d "$STATUS_DIR" ]; then
        generate_pm_mcp_config
    fi
}

# Timing
export POLL_INTERVAL=10  # seconds between status checks
export AGENT_TIMEOUT=300 # seconds before considering agent stuck

# Parallel execution limits (set high since you have unlimited tiers)
export MAX_PARALLEL_AGENTS=20

# Conflict resolution
export MAX_CONFLICT_RETRIES=2  # Max attempts to resolve merge conflicts

# Available agents pool with their specializations
# claude = API specialist (chrome-devtools MCP)
# codex = code generator (no MCP, fast)
# gemini = visual inspector (chrome-devtools MCP)
declare -a AGENTS=("claude" "codex" "gemini")
