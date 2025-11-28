# Multi-Agent AI Orchestrator

A bash-based orchestration system that coordinates multiple AI coding agents (Claude, Codex, Gemini) working in parallel on the same codebase using git branches for isolation.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│           orchestrator.sh (always-on bash loop)             │
└──────────────────────────┬──────────────────────────────────┘
                           │ invokes
                           ▼
              ┌────────────────────────┐
              │   Claude Code (PM)     │
              │   - Plans projects     │
              │   - Reviews work       │
              │   - Approves merges    │
              └───────────┬────────────┘
                          │ dispatches
          ┌───────────────┼───────────────┐
          ▼               ▼               ▼
    ┌──────────┐    ┌──────────┐    ┌──────────┐
    │  Claude  │    │  Codex   │    │  Gemini  │
    │ branch/a │    │ branch/b │    │ branch/c │
    └──────────┘    └──────────┘    └──────────┘
                          │
                          ▼
                   Git Repository
```

## Quick Start

```bash
# Start a new project
./orchestrator.sh start "Build a REST API with user authentication"

# Resume an existing project
./orchestrator.sh resume

# List all projects
./orchestrator.sh list

# Check project status
./orchestrator.sh status [project-name]

# View session logs
./orchestrator.sh logs <project-name>

# Start web UI dashboard
./orchestrator.sh web
```

## Web UI

The orchestrator includes a web-based dashboard for monitoring and interacting with the system.

```bash
./orchestrator.sh web
```

This starts:
- **Frontend**: http://localhost:3000 (React dashboard)
- **Backend**: http://localhost:3001 (API + WebSocket)

### Features

- **Task Board**: Kanban-style view of all tasks (Blocked, Ready, Running, Completed)
- **Agent Pool**: Real-time status of all agents
- **PM Chat**: Respond to PM questions via web interface
- **Activity Log**: Live stream of orchestrator events

When the web UI is running, PM escalations are automatically routed to the web interface instead of the terminal.

## How It Works

1. **Project Planning**: Claude Code acts as Project Manager (PM), breaking down your project description into parallel tasks
2. **Agent Dispatch**: Tasks are distributed to available agents (Claude, Codex, Gemini), each working on isolated git branches
3. **Continuous Monitoring**: The orchestrator loop polls for completed work every 10 seconds
4. **Code Review**: PM reviews completed branches and decides to approve, request changes, or reject
5. **Merge**: Approved branches are merged back to main

## Project Structure

```
├── launch-files/
│   ├── orchestrator.sh      # Main entry point
│   ├── config.sh            # Configuration (agent commands, limits)
│   ├── lib/
│   │   ├── pm.sh            # PM functions (planning, review)
│   │   ├── dispatch.sh      # Agent spawning & task distribution
│   │   ├── monitor.sh       # Status tracking & completion detection
│   │   └── messages.sh      # Inter-agent messaging
│   ├── mcp/                 # MCP server configurations
│   └── web-ui/              # Web dashboard
│       ├── server/          # Express + WebSocket backend
│       └── client/          # React frontend
├── runtime/
│   ├── workspace/           # Active workspace with git repo
│   ├── agents/              # Per-agent working directories
│   ├── status/              # Runtime state (tasks.json, *.status files)
│   └── projects/            # All project directories
└── FINDINGS.md              # Detailed documentation & test results
```

## Configuration

Edit `launch-files/config.sh` to customize:

```bash
# Agent commands
CLAUDE_CMD="claude -p --dangerously-skip-permissions"
CODEX_CMD="codex exec --skip-git-repo-check --full-auto"
GEMINI_CMD="gemini -y"

# Execution limits
MAX_PARALLEL_AGENTS=20
POLL_INTERVAL=10      # seconds between status checks
AGENT_TIMEOUT=300     # seconds before considering agent stuck
```

## Requirements

- Bash 4.0+
- Git
- Python 3 (for JSON parsing)
- AI CLI tools installed:
  - [Claude Code](https://claude.ai/claude-code)
  - [Codex CLI](https://github.com/openai/codex)
  - [Gemini CLI](https://github.com/google/gemini-cli)

## Subscription Tiers

For unlimited parallel agents, the following tiers are recommended:

| Service | Tier | Limits |
|---------|------|--------|
| Claude | Max | Unlimited |
| ChatGPT | Teams | Unlimited |
| Gemini | Pro | Unlimited |

## Features

- ✅ Always-on orchestration loop
- ✅ PM task planning with dependency support
- ✅ Multi-agent parallel dispatch
- ✅ Git branch isolation per agent
- ✅ Agent completion detection
- ✅ PM code review workflow
- ✅ MCP integration (Chrome DevTools, custom servers)
- ✅ Resource/credential management
- ✅ Session logging
- ✅ **Web UI Dashboard** - Real-time monitoring
- ✅ **Web-based PM Chat** - Respond to PM questions via browser

## License

MIT
