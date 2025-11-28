# Web UI Implementation Plan

## Overview

Create a web-based UI for the multi-agent orchestrator that allows users to:
1. See real-time progress of tasks and agents
2. Communicate with the PM (receive questions, send responses)
3. Monitor activity logs and agent status

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         React Frontend                               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │
│  │ Task Board   │  │ Agent Pool   │  │ PM Chat Interface        │  │
│  │ (Kanban)     │  │ Status       │  │ (questions/responses)    │  │
│  └──────────────┘  └──────────────┘  └──────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                     Activity Log / Timeline                    │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                              │ WebSocket
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Node.js/Express Backend                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │
│  │ REST API     │  │ WebSocket    │  │ File Watchers            │  │
│  │ /api/*       │  │ Server       │  │ (chokidar)               │  │
│  └──────────────┘  └──────────────┘  └──────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                              │ File I/O
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     Existing Orchestrator Files                      │
│  runtime/status/tasks.json, *.status, *.completed                   │
│  runtime/status/messages/outbox.json, inbox.json, status.json       │
└─────────────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
launch-files/
└── web-ui/
    ├── package.json
    ├── server/
    │   ├── index.js           # Express server entry
    │   ├── routes/
    │   │   ├── api.js         # REST API routes
    │   │   └── projects.js    # Project management routes
    │   ├── websocket/
    │   │   └── handler.js     # WebSocket event handling
    │   ├── watchers/
    │   │   └── fileWatcher.js # File system watchers
    │   └── services/
    │       ├── orchestrator.js # Interface to orchestrator state
    │       └── messaging.js    # User ↔ PM messaging
    └── client/
        ├── package.json
        ├── src/
        │   ├── App.jsx
        │   ├── index.jsx
        │   ├── components/
        │   │   ├── Dashboard.jsx
        │   │   ├── TaskBoard.jsx
        │   │   ├── AgentPool.jsx
        │   │   ├── PMChat.jsx
        │   │   ├── ActivityLog.jsx
        │   │   └── ProjectSelector.jsx
        │   ├── hooks/
        │   │   ├── useWebSocket.js
        │   │   └── useOrchestrator.js
        │   ├── context/
        │   │   └── OrchestratorContext.jsx
        │   └── styles/
        │       └── main.css
        └── public/
            └── index.html
```

## Implementation Tasks

### Phase 1: Backend Foundation

1. **Create Express server** (`server/index.js`)
   - Set up Express with CORS
   - Configure WebSocket server (ws library)
   - Serve static files for React build
   - Environment config for STATUS_DIR path

2. **File watchers** (`server/watchers/fileWatcher.js`)
   - Watch `tasks.json` for task status changes
   - Watch `*.status`, `*.completed`, `*.approved` files
   - Watch `messages/outbox.json` for new PM→User messages
   - Watch `messages/status.json` for agent status updates
   - Emit WebSocket events on changes

3. **REST API** (`server/routes/api.js`)
   - `GET /api/projects` - List all projects
   - `GET /api/projects/:id` - Get project details
   - `GET /api/tasks` - Get all tasks with status
   - `GET /api/agents` - Get agent pool status
   - `GET /api/messages` - Get pending PM questions
   - `POST /api/messages/:id/respond` - User responds to PM
   - `GET /api/logs` - Get recent activity logs

4. **Messaging service** (`server/services/messaging.js`)
   - Read pending questions from `outbox.json` (type: escalation)
   - Write user responses to `inbox.json`
   - Mark messages as handled

### Phase 2: React Frontend

5. **Project setup** (`client/`)
   - Initialize React with Vite
   - Install dependencies: socket.io-client, tailwindcss
   - Set up routing (react-router-dom)

6. **WebSocket hook** (`hooks/useWebSocket.js`)
   - Connect to backend WebSocket
   - Handle reconnection
   - Dispatch events to React state

7. **Dashboard component** (`components/Dashboard.jsx`)
   - Layout with sidebar and main content
   - Project selector dropdown
   - Overall progress summary

8. **Task Board** (`components/TaskBoard.jsx`)
   - Kanban-style columns: Blocked, Ready, Running, Completed
   - Task cards with details
   - Real-time updates via WebSocket

9. **Agent Pool** (`components/AgentPool.jsx`)
   - List of agents with status indicators
   - Active/Standby/Terminated states
   - Current task assignment

10. **PM Chat Interface** (`components/PMChat.jsx`)
    - Chat-like interface for PM questions
    - User input area for responses
    - Notification badge for pending questions
    - Message history

11. **Activity Log** (`components/ActivityLog.jsx`)
    - Timeline of events
    - Agent status changes
    - Task completions
    - Error notifications

### Phase 3: Integration

12. **Orchestrator integration**
    - Modify `lib/messages.sh` to check for web responses
    - Add `escalate_to_web()` function as alternative to terminal
    - Detect if web UI is running and route accordingly

13. **Startup script**
    - Add `./orchestrator.sh web` command to start web UI
    - Or run as separate `npm run dev` in web-ui folder

## API Endpoints

### Projects
```
GET /api/projects
Response: [{ name, description, created, status }]

GET /api/projects/:name
Response: { name, description, tasks, agents, messages }
```

### Tasks
```
GET /api/tasks?project=:name
Response: { tasks: [{ id, status, branch, agent, description, depends_on }] }
```

### Agents
```
GET /api/agents?project=:name
Response: { agents: { [id]: { role, status, currentTask, lastSeen } } }
```

### Messages (PM ↔ User)
```
GET /api/messages?project=:name&pending=true
Response: { messages: [{ id, from, question, priority, timestamp }] }

POST /api/messages/:id/respond
Body: { response: "user's answer" }
Response: { success: true }
```

## WebSocket Events

### Server → Client
```javascript
// Task status change
{ type: 'task:update', task: { id, status, ... } }

// Agent status change
{ type: 'agent:update', agent: { id, status, ... } }

// New PM question for user
{ type: 'pm:question', message: { id, question, priority, ... } }

// Activity log entry
{ type: 'activity', entry: { timestamp, type, message } }
```

### Client → Server
```javascript
// User responds to PM
{ type: 'pm:respond', messageId, response }

// Request full state refresh
{ type: 'state:refresh' }
```

## Tech Stack

- **Backend**: Node.js, Express, ws (WebSocket), chokidar (file watching)
- **Frontend**: React 18, Vite, TailwindCSS, socket.io-client
- **State Management**: React Context + useReducer

## Milestones

1. **M1**: Backend serves static files, REST API for tasks/agents
2. **M2**: File watchers + WebSocket push updates
3. **M3**: React dashboard with task board and agent pool
4. **M4**: PM chat interface functional
5. **M5**: Full integration with orchestrator

## Questions / Decisions

None - ready to implement with React + Node.js/Express + WebSocket.
