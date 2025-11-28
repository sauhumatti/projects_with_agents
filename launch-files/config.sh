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

# Function to set project paths (called when project is selected)
set_project_paths() {
    local project_name="$1"
    export PROJECT_DIR="$PROJECTS_DIR/$project_name"
    export WORKSPACE="$PROJECT_DIR/workspace"
    export AGENTS_DIR="$PROJECT_DIR/agents"
    export STATUS_DIR="$PROJECT_DIR/status"
    export LOGS_DIR="$PROJECT_DIR/logs"
    export RESOURCES_FILE="$STATUS_DIR/resources.env"
}

# MCP Configurations (unified chrome-devtools for all agents)
export MCP_DIR="$LAUNCH_DIR/mcp"
export CHROME_DEVTOOLS_MCP_CONFIG="$MCP_DIR/chrome-devtools-mcp.json"

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

# PM Configuration (uses Claude Code as the PM, with chrome-devtools for testing)
export PM_CMD="claude -p --dangerously-skip-permissions --mcp-config=$CHROME_DEVTOOLS_MCP_CONFIG"

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
