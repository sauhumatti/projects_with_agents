#!/usr/bin/env node

/**
 * PM Control MCP Server
 * Gives the Project Manager direct control over the agent pool
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import fs from "fs";
import path from "path";
import crypto from "crypto";
import { spawn } from "child_process";

// Get directories from environment
const STATUS_DIR = process.env.STATUS_DIR || "/tmp/orchestrator";
const MESSAGES_DIR = path.join(STATUS_DIR, "messages");
const AGENTS_DIR = process.env.AGENTS_DIR || path.join(STATUS_DIR, "agents");
const WORKSPACE = process.env.WORKSPACE || process.cwd();

// Agent command templates (from environment or defaults)
const CLAUDE_CMD = process.env.CLAUDE_CMD || "claude --dangerously-skip-permissions";
const CODEX_CMD = process.env.CODEX_CMD || "codex --dangerously-skip-permissions";
const GEMINI_CMD = process.env.GEMINI_CMD || "gemini";

// File paths
const AGENT_POOL_FILE = path.join(MESSAGES_DIR, "agent_pool.json");
const ASSIGNMENTS_FILE = path.join(MESSAGES_DIR, "assignments.json");
const OUTBOX_FILE = path.join(MESSAGES_DIR, "outbox.json");
const INBOX_FILE = path.join(MESSAGES_DIR, "inbox.json");

// Track spawned agent processes
const agentProcesses = new Map();

// Ensure directories exist
if (!fs.existsSync(MESSAGES_DIR)) {
  fs.mkdirSync(MESSAGES_DIR, { recursive: true });
}
if (!fs.existsSync(AGENTS_DIR)) {
  fs.mkdirSync(AGENTS_DIR, { recursive: true });
}

// Helper to read JSON file safely
function readJsonFile(filePath) {
  try {
    if (fs.existsSync(filePath)) {
      return JSON.parse(fs.readFileSync(filePath, "utf-8"));
    }
  } catch (e) {
    // File might be being written
  }
  return {};
}

// Helper to write JSON file atomically
function writeJsonFile(filePath, data) {
  const tmpPath = filePath + ".tmp";
  fs.writeFileSync(tmpPath, JSON.stringify(data, null, 2));
  fs.renameSync(tmpPath, filePath);
}

// Generate agent ID
function generateAgentId(role, type) {
  const shortId = crypto.randomUUID().split('-')[0];
  return `${role}-${type}-${shortId}`;
}

// Spawn a new persistent agent
async function spawnAgent(role, type, capabilities = []) {
  const agentId = generateAgentId(role, type);
  const agentWorkspace = path.join(AGENTS_DIR, agentId);

  // Create agent workspace
  fs.mkdirSync(agentWorkspace, { recursive: true });

  // Clone the main workspace
  try {
    const { execSync } = await import("child_process");
    execSync(`git clone "${WORKSPACE}" "${agentWorkspace}"`, { stdio: 'pipe' });
  } catch (e) {
    // If clone fails, just create the directory
    console.error(`Warning: Could not clone workspace: ${e.message}`);
  }

  // Build the agent prompt
  const agentPrompt = `You are a persistent ${role} agent (ID: ${agentId}).

YOUR ROLE: ${role}
YOUR CAPABILITIES: ${capabilities.join(', ') || 'general'}

WORKING DIRECTORY: ${agentWorkspace}

YOU ARE A PERSISTENT AGENT:
You do NOT exit after completing a task. Instead:
1. Complete your assigned work
2. Call task_complete(summary, files_changed) to report completion
3. Call await_assignment(capabilities) to wait for your next task
4. When you receive a new assignment, work on it
5. Repeat until await_assignment times out (10 min with no work)

COMMUNICATION:
- ask_pm(question) - Ask the Project Manager for clarification (blocks until response)
- send_status(status, message) - Update PM on your progress
- notify_pm(message, type) - Send notification to PM
- get_messages() - Check for incoming messages

LIFECYCLE:
- task_complete(summary) - Report task done, include files you changed
- await_assignment(capabilities) - Enter standby, wait for next task

You are now in STANDBY mode. Wait for your first assignment by calling await_assignment().
Start by calling: await_assignment(${JSON.stringify(capabilities)})`;

  // Determine command based on type
  let cmd, args;
  switch (type.toLowerCase()) {
    case 'claude':
      cmd = 'claude';
      args = ['--dangerously-skip-permissions', '-p', agentPrompt];
      break;
    case 'codex':
      cmd = 'codex';
      args = ['--dangerously-skip-permissions', '-C', agentWorkspace, agentPrompt];
      break;
    case 'gemini':
      cmd = 'gemini';
      args = ['-p', agentPrompt];
      break;
    default:
      throw new Error(`Unknown agent type: ${type}`);
  }

  // Set up environment for the agent
  const env = {
    ...process.env,
    ORCHESTRATOR_MESSAGES_DIR: MESSAGES_DIR,
    ORCHESTRATOR_AGENT_ID: agentId,
    ORCHESTRATOR_TASK_ID: 'standby',
  };

  // Spawn the agent process
  const agentProcess = spawn(cmd, args, {
    cwd: agentWorkspace,
    env: env,
    stdio: ['pipe', 'pipe', 'pipe'],
    detached: true,
  });

  // Store process reference
  agentProcesses.set(agentId, {
    process: agentProcess,
    pid: agentProcess.pid,
    role: role,
    type: type,
    workspace: agentWorkspace,
    startedAt: new Date().toISOString(),
  });

  // Register in agent pool
  const pool = readJsonFile(AGENT_POOL_FILE);
  pool.agents = pool.agents || {};
  pool.agents[agentId] = {
    role: role,
    type: type,
    capabilities: capabilities,
    status: 'starting',
    currentTask: null,
    workspace: agentWorkspace,
    pid: agentProcess.pid,
    registeredAt: new Date().toISOString(),
    lastSeen: new Date().toISOString(),
  };
  writeJsonFile(AGENT_POOL_FILE, pool);

  // Handle process events
  agentProcess.on('exit', (code) => {
    console.error(`Agent ${agentId} exited with code ${code}`);
    agentProcesses.delete(agentId);

    // Update pool status
    const pool = readJsonFile(AGENT_POOL_FILE);
    if (pool.agents && pool.agents[agentId]) {
      pool.agents[agentId].status = 'terminated';
      pool.agents[agentId].exitCode = code;
      pool.agents[agentId].terminatedAt = new Date().toISOString();
      writeJsonFile(AGENT_POOL_FILE, pool);
    }
  });

  // Log stdout/stderr
  agentProcess.stdout.on('data', (data) => {
    console.error(`[${agentId}] ${data.toString()}`);
  });
  agentProcess.stderr.on('data', (data) => {
    console.error(`[${agentId}] ${data.toString()}`);
  });

  // Unref so the PM can exit independently
  agentProcess.unref();

  return {
    agentId: agentId,
    pid: agentProcess.pid,
    workspace: agentWorkspace,
    status: 'starting',
  };
}

// Assign a task to an agent
function assignTask(agentId, taskId, branch, description) {
  const assignments = readJsonFile(ASSIGNMENTS_FILE);
  assignments.pending = assignments.pending || [];

  const assignment = {
    id: crypto.randomUUID(),
    agentId: agentId,
    taskId: taskId,
    branch: branch || `feature/${taskId}`,
    type: 'assigned',
    description: description,
    assignedAt: new Date().toISOString(),
  };

  assignments.pending.push(assignment);
  writeJsonFile(ASSIGNMENTS_FILE, assignments);

  // Update pool status
  const pool = readJsonFile(AGENT_POOL_FILE);
  if (pool.agents && pool.agents[agentId]) {
    pool.agents[agentId].status = 'assigned';
    pool.agents[agentId].currentTask = taskId;
    pool.agents[agentId].lastSeen = new Date().toISOString();
    writeJsonFile(AGENT_POOL_FILE, pool);
  }

  return assignment;
}

// List all agents
function listAgents(statusFilter = null) {
  const pool = readJsonFile(AGENT_POOL_FILE);
  const agents = pool.agents || {};

  const result = [];
  for (const [agentId, info] of Object.entries(agents)) {
    if (statusFilter && info.status !== statusFilter) {
      continue;
    }
    result.push({
      id: agentId,
      role: info.role,
      type: info.type,
      status: info.status,
      currentTask: info.currentTask,
      capabilities: info.capabilities || [],
      lastSeen: info.lastSeen,
    });
  }

  return result;
}

// Terminate an agent
function terminateAgent(agentId) {
  const agentInfo = agentProcesses.get(agentId);

  if (agentInfo && agentInfo.process) {
    try {
      process.kill(agentInfo.pid, 'SIGTERM');
    } catch (e) {
      // Process might already be dead
    }
  }

  // Update pool
  const pool = readJsonFile(AGENT_POOL_FILE);
  if (pool.agents && pool.agents[agentId]) {
    pool.agents[agentId].status = 'terminated';
    pool.agents[agentId].terminatedAt = new Date().toISOString();
    writeJsonFile(AGENT_POOL_FILE, pool);
  }

  agentProcesses.delete(agentId);

  return { terminated: agentId };
}

// Broadcast message to all agents
function broadcastMessage(message, type = 'info') {
  const pool = readJsonFile(AGENT_POOL_FILE);
  const agents = pool.agents || {};

  const inbox = readJsonFile(INBOX_FILE);
  inbox.messages = inbox.messages || [];

  const broadcastId = crypto.randomUUID();

  for (const agentId of Object.keys(agents)) {
    if (agents[agentId].status === 'active' || agents[agentId].status === 'standby') {
      inbox.messages.push({
        id: crypto.randomUUID(),
        broadcastId: broadcastId,
        from: 'pm',
        to: agentId,
        type: type,
        message: message,
        timestamp: new Date().toISOString(),
        read: false,
      });
    }
  }

  writeJsonFile(INBOX_FILE, inbox);

  return { broadcastId: broadcastId, recipientCount: Object.keys(agents).length };
}

// Get agent status details
function getAgentStatus(agentId) {
  const pool = readJsonFile(AGENT_POOL_FILE);

  if (!pool.agents || !pool.agents[agentId]) {
    return null;
  }

  const agent = pool.agents[agentId];

  // Check if process is still running
  const processInfo = agentProcesses.get(agentId);
  const isRunning = processInfo && processInfo.process && !processInfo.process.killed;

  return {
    ...agent,
    processRunning: isRunning,
    pid: processInfo?.pid || agent.pid,
  };
}

// Create MCP server
const server = new Server(
  {
    name: "pm-control",
    version: "1.0.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// Define available tools
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: "spawn_agent",
        description: "Spawn a new persistent agent that stays alive between tasks. The agent will enter standby mode and wait for assignments.",
        inputSchema: {
          type: "object",
          properties: {
            role: {
              type: "string",
              description: "The role of the agent (e.g., 'researcher', 'builder', 'tester', 'reviewer')"
            },
            type: {
              type: "string",
              enum: ["claude", "codex", "gemini"],
              description: "The AI model to use for this agent"
            },
            capabilities: {
              type: "array",
              items: { type: "string" },
              description: "List of capabilities (e.g., ['coding', 'testing', 'research', 'visual-qa'])"
            }
          },
          required: ["role", "type"]
        }
      },
      {
        name: "assign_task",
        description: "Assign a task to a standby agent. The agent will receive the assignment and begin working.",
        inputSchema: {
          type: "object",
          properties: {
            agent_id: {
              type: "string",
              description: "The ID of the agent to assign work to"
            },
            task_id: {
              type: "string",
              description: "Unique identifier for this task"
            },
            branch: {
              type: "string",
              description: "Git branch name for this task (optional, defaults to feature/task_id)"
            },
            description: {
              type: "string",
              description: "Detailed description of what the agent should do"
            }
          },
          required: ["agent_id", "task_id", "description"]
        }
      },
      {
        name: "list_agents",
        description: "List all agents in the pool with their current status.",
        inputSchema: {
          type: "object",
          properties: {
            status: {
              type: "string",
              enum: ["all", "active", "standby", "terminated"],
              description: "Filter by status (default: all)"
            }
          }
        }
      },
      {
        name: "get_agent_status",
        description: "Get detailed status of a specific agent.",
        inputSchema: {
          type: "object",
          properties: {
            agent_id: {
              type: "string",
              description: "The ID of the agent to check"
            }
          },
          required: ["agent_id"]
        }
      },
      {
        name: "terminate_agent",
        description: "Terminate a specific agent. The agent process will be killed.",
        inputSchema: {
          type: "object",
          properties: {
            agent_id: {
              type: "string",
              description: "The ID of the agent to terminate"
            }
          },
          required: ["agent_id"]
        }
      },
      {
        name: "broadcast_message",
        description: "Send a message to all active agents.",
        inputSchema: {
          type: "object",
          properties: {
            message: {
              type: "string",
              description: "The message to broadcast"
            },
            type: {
              type: "string",
              enum: ["info", "warning", "urgent", "directive"],
              description: "Type of message (default: info)"
            }
          },
          required: ["message"]
        }
      },
      {
        name: "terminate_all",
        description: "Terminate all agents in the pool. Use with caution.",
        inputSchema: {
          type: "object",
          properties: {
            confirm: {
              type: "boolean",
              description: "Must be true to confirm termination of all agents"
            }
          },
          required: ["confirm"]
        }
      }
    ]
  };
});

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "spawn_agent": {
      const { role, type, capabilities = [] } = args;

      try {
        const result = await spawnAgent(role, type, capabilities);
        return {
          content: [
            {
              type: "text",
              text: `Agent spawned successfully!\n\nAgent ID: ${result.agentId}\nPID: ${result.pid}\nWorkspace: ${result.workspace}\nStatus: ${result.status}\n\nThe agent is starting up and will enter standby mode. Use assign_task() to give it work.`
            }
          ]
        };
      } catch (e) {
        return {
          content: [
            {
              type: "text",
              text: `Failed to spawn agent: ${e.message}`
            }
          ]
        };
      }
    }

    case "assign_task": {
      const { agent_id, task_id, branch, description } = args;

      const agent = getAgentStatus(agent_id);
      if (!agent) {
        return {
          content: [{ type: "text", text: `Agent not found: ${agent_id}` }]
        };
      }

      if (agent.status !== 'standby' && agent.status !== 'starting') {
        return {
          content: [{ type: "text", text: `Agent ${agent_id} is not available (status: ${agent.status}). Only standby agents can receive assignments.` }]
        };
      }

      const assignment = assignTask(agent_id, task_id, branch, description);

      return {
        content: [
          {
            type: "text",
            text: `Task assigned!\n\nAssignment ID: ${assignment.id}\nAgent: ${agent_id}\nTask: ${task_id}\nBranch: ${assignment.branch}\n\nThe agent will pick up this assignment on its next poll cycle.`
          }
        ]
      };
    }

    case "list_agents": {
      const { status = "all" } = args;
      const filter = status === "all" ? null : status;
      const agents = listAgents(filter);

      if (agents.length === 0) {
        return {
          content: [{ type: "text", text: "No agents in pool." }]
        };
      }

      let output = "AGENT POOL STATUS\n" + "=".repeat(60) + "\n\n";

      // Group by status
      const byStatus = {};
      for (const agent of agents) {
        if (!byStatus[agent.status]) byStatus[agent.status] = [];
        byStatus[agent.status].push(agent);
      }

      for (const [status, statusAgents] of Object.entries(byStatus)) {
        output += `${status.toUpperCase()} (${statusAgents.length}):\n`;
        for (const agent of statusAgents) {
          output += `  [${agent.id}]\n`;
          output += `    Role: ${agent.role} | Type: ${agent.type}\n`;
          output += `    Capabilities: ${agent.capabilities.join(', ') || 'none'}\n`;
          if (agent.currentTask) {
            output += `    Current Task: ${agent.currentTask}\n`;
          }
          output += `    Last Seen: ${agent.lastSeen}\n`;
          output += "\n";
        }
      }

      return {
        content: [{ type: "text", text: output }]
      };
    }

    case "get_agent_status": {
      const { agent_id } = args;
      const agent = getAgentStatus(agent_id);

      if (!agent) {
        return {
          content: [{ type: "text", text: `Agent not found: ${agent_id}` }]
        };
      }

      return {
        content: [
          {
            type: "text",
            text: `AGENT: ${agent_id}\n` +
              `Status: ${agent.status}\n` +
              `Role: ${agent.role}\n` +
              `Type: ${agent.type}\n` +
              `Capabilities: ${(agent.capabilities || []).join(', ')}\n` +
              `Current Task: ${agent.currentTask || 'none'}\n` +
              `Workspace: ${agent.workspace}\n` +
              `PID: ${agent.pid || 'unknown'}\n` +
              `Process Running: ${agent.processRunning ? 'yes' : 'no'}\n` +
              `Registered: ${agent.registeredAt}\n` +
              `Last Seen: ${agent.lastSeen}`
          }
        ]
      };
    }

    case "terminate_agent": {
      const { agent_id } = args;
      const result = terminateAgent(agent_id);

      return {
        content: [
          {
            type: "text",
            text: `Agent ${result.terminated} has been terminated.`
          }
        ]
      };
    }

    case "broadcast_message": {
      const { message, type = "info" } = args;
      const result = broadcastMessage(message, type);

      return {
        content: [
          {
            type: "text",
            text: `Broadcast sent!\n\nBroadcast ID: ${result.broadcastId}\nRecipients: ${result.recipientCount} agents\nType: ${type}\nMessage: ${message}`
          }
        ]
      };
    }

    case "terminate_all": {
      const { confirm } = args;

      if (!confirm) {
        return {
          content: [{ type: "text", text: "Termination cancelled. Set confirm=true to proceed." }]
        };
      }

      const agents = listAgents();
      let terminated = 0;

      for (const agent of agents) {
        if (agent.status !== 'terminated') {
          terminateAgent(agent.id);
          terminated++;
        }
      }

      return {
        content: [
          {
            type: "text",
            text: `Terminated ${terminated} agents.`
          }
        ]
      };
    }

    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

// Start server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("PM Control MCP Server running");
}

main().catch(console.error);
