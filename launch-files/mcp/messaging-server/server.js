#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import fs from "fs";
import path from "path";
import crypto from "crypto";

// Get messaging directory from environment or use default
const MESSAGES_DIR = process.env.ORCHESTRATOR_MESSAGES_DIR ||
  path.join(process.env.STATUS_DIR || "/tmp", "messages");
const AGENT_ID = process.env.ORCHESTRATOR_AGENT_ID || "unknown-agent";
const TASK_ID = process.env.ORCHESTRATOR_TASK_ID || "unknown-task";

// Ensure messages directory exists
if (!fs.existsSync(MESSAGES_DIR)) {
  fs.mkdirSync(MESSAGES_DIR, { recursive: true });
}

// Message file paths
const OUTBOX_FILE = path.join(MESSAGES_DIR, "outbox.json");
const INBOX_FILE = path.join(MESSAGES_DIR, "inbox.json");
const STATUS_FILE = path.join(MESSAGES_DIR, "status.json");
const AGENT_POOL_FILE = path.join(MESSAGES_DIR, "agent_pool.json");
const ASSIGNMENTS_FILE = path.join(MESSAGES_DIR, "assignments.json");

// Helper to read JSON file safely
function readJsonFile(filePath) {
  try {
    if (fs.existsSync(filePath)) {
      return JSON.parse(fs.readFileSync(filePath, "utf-8"));
    }
  } catch (e) {
    // File might be being written, return empty
  }
  return { messages: [] };
}

// Helper to write JSON file atomically
function writeJsonFile(filePath, data) {
  const tmpPath = filePath + ".tmp";
  fs.writeFileSync(tmpPath, JSON.stringify(data, null, 2));
  fs.renameSync(tmpPath, filePath);
}

// Add message to outbox (agent → PM/user)
function sendMessage(to, question, priority = "normal") {
  const outbox = readJsonFile(OUTBOX_FILE);
  const messageId = crypto.randomUUID();

  const message = {
    id: messageId,
    from: AGENT_ID,
    task: TASK_ID,
    to: to,  // "pm" or "user"
    question: question,
    priority: priority,
    timestamp: new Date().toISOString(),
    status: "pending"
  };

  outbox.messages.push(message);
  writeJsonFile(OUTBOX_FILE, outbox);

  return messageId;
}

// Check for response to a specific message
function checkResponse(messageId) {
  const inbox = readJsonFile(INBOX_FILE);
  const response = inbox.messages.find(m => m.replyTo === messageId);
  return response || null;
}

// Wait for response with polling
async function waitForResponse(messageId, timeoutMs = 300000) {
  const startTime = Date.now();
  const pollInterval = 1000; // 1 second

  while (Date.now() - startTime < timeoutMs) {
    const response = checkResponse(messageId);
    if (response) {
      return response;
    }
    await new Promise(resolve => setTimeout(resolve, pollInterval));
  }

  return null; // Timeout
}

// Update status (non-blocking)
function updateStatus(status, details = {}) {
  const statusData = readJsonFile(STATUS_FILE);

  statusData.agents = statusData.agents || {};
  statusData.agents[AGENT_ID] = {
    task: TASK_ID,
    status: status,
    details: details,
    timestamp: new Date().toISOString()
  };

  writeJsonFile(STATUS_FILE, statusData);
}

// Register agent in pool
function registerAgent(role, capabilities = []) {
  const pool = readJsonFile(AGENT_POOL_FILE);
  pool.agents = pool.agents || {};

  pool.agents[AGENT_ID] = {
    role: role,
    capabilities: capabilities,
    status: "active",
    currentTask: TASK_ID,
    registeredAt: new Date().toISOString(),
    lastSeen: new Date().toISOString()
  };

  writeJsonFile(AGENT_POOL_FILE, pool);
}

// Update agent status in pool
function updateAgentPool(status, currentTask = null) {
  const pool = readJsonFile(AGENT_POOL_FILE);
  pool.agents = pool.agents || {};

  if (pool.agents[AGENT_ID]) {
    pool.agents[AGENT_ID].status = status;
    pool.agents[AGENT_ID].currentTask = currentTask;
    pool.agents[AGENT_ID].lastSeen = new Date().toISOString();
  }

  writeJsonFile(AGENT_POOL_FILE, pool);
}

// Check for new assignment
function checkAssignment() {
  const assignments = readJsonFile(ASSIGNMENTS_FILE);
  const myAssignment = assignments.pending?.find(a => a.agentId === AGENT_ID);
  return myAssignment || null;
}

// Mark assignment as accepted
function acceptAssignment(assignmentId) {
  const assignments = readJsonFile(ASSIGNMENTS_FILE);
  assignments.pending = assignments.pending || [];
  assignments.accepted = assignments.accepted || [];

  const idx = assignments.pending.findIndex(a => a.id === assignmentId);
  if (idx >= 0) {
    const assignment = assignments.pending.splice(idx, 1)[0];
    assignment.acceptedAt = new Date().toISOString();
    assignments.accepted.push(assignment);
    writeJsonFile(ASSIGNMENTS_FILE, assignments);
    return assignment;
  }
  return null;
}

// Wait for new assignment (blocking)
async function waitForAssignment(timeoutMs = 600000) {
  const startTime = Date.now();
  const pollInterval = 2000; // 2 seconds

  // Mark as standby in pool
  updateAgentPool("standby", null);
  updateStatus("standby", { waiting_for: "assignment" });

  while (Date.now() - startTime < timeoutMs) {
    const assignment = checkAssignment();
    if (assignment) {
      // Accept and return
      acceptAssignment(assignment.id);
      updateAgentPool("active", assignment.taskId);
      updateStatus("in_progress", { task: assignment.taskId });
      return assignment;
    }
    await new Promise(resolve => setTimeout(resolve, pollInterval));
  }

  return null; // Timeout - agent should terminate
}

// Create MCP server
const server = new Server(
  {
    name: "orchestrator-messaging",
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
        name: "ask_pm",
        description: "Ask the Project Manager a question and wait for a response. Use this when you need clarification, approval, or guidance on how to proceed. The PM can see your code and provide specific direction. NOTE: You cannot contact the user directly - all communication goes through the PM.",
        inputSchema: {
          type: "object",
          properties: {
            question: {
              type: "string",
              description: "Your question for the PM. Be specific about what you need help with."
            },
            context: {
              type: "string",
              description: "Optional additional context (e.g., code snippet, error message)"
            },
            priority: {
              type: "string",
              enum: ["low", "normal", "high", "blocking"],
              description: "Priority level. Use 'blocking' if you cannot proceed without an answer."
            }
          },
          required: ["question"]
        }
      },
      {
        name: "send_status",
        description: "Send a status update about your progress to the PM. This does NOT wait for a response.",
        inputSchema: {
          type: "object",
          properties: {
            status: {
              type: "string",
              enum: ["starting", "in_progress", "blocked", "testing", "completing", "error"],
              description: "Current status"
            },
            message: {
              type: "string",
              description: "Brief description of what you're doing or what happened"
            },
            progress: {
              type: "number",
              minimum: 0,
              maximum: 100,
              description: "Optional progress percentage (0-100)"
            }
          },
          required: ["status", "message"]
        }
      },
      {
        name: "get_messages",
        description: "Check for any incoming messages from the PM. Use this periodically if you want to check for updates without blocking.",
        inputSchema: {
          type: "object",
          properties: {
            unreadOnly: {
              type: "boolean",
              description: "If true, only return unread messages",
              default: true
            }
          }
        }
      },
      {
        name: "notify_pm",
        description: "Send a notification to the PM without waiting for a response. Use this for FYI messages, warnings, or non-blocking updates.",
        inputSchema: {
          type: "object",
          properties: {
            message: {
              type: "string",
              description: "The notification message"
            },
            type: {
              type: "string",
              enum: ["info", "warning", "error", "success"],
              description: "Type of notification"
            }
          },
          required: ["message"]
        }
      },
      {
        name: "task_complete",
        description: "Report that your current task is complete. Call this when you've finished the assigned work. You'll then enter standby mode waiting for a new assignment from the PM.",
        inputSchema: {
          type: "object",
          properties: {
            summary: {
              type: "string",
              description: "Brief summary of what you accomplished"
            },
            files_changed: {
              type: "array",
              items: { type: "string" },
              description: "List of files you created or modified"
            }
          },
          required: ["summary"]
        }
      },
      {
        name: "await_assignment",
        description: "Enter standby mode and wait for the PM to assign you a new task. This blocks until a new task is assigned or timeout (10 min). Use this after completing a task to stay available for more work.",
        inputSchema: {
          type: "object",
          properties: {
            capabilities: {
              type: "array",
              items: { type: "string" },
              description: "Your capabilities (e.g., 'research', 'coding', 'testing', 'visual-qa')"
            }
          }
        }
      }
    ]
  };
});

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "ask_pm": {
      const { question, context, priority = "normal" } = args;
      const fullQuestion = context ? `${question}\n\nContext:\n${context}` : question;

      updateStatus("blocked", { waiting_for: "pm", question: question });

      const messageId = sendMessage("pm", fullQuestion, priority);

      // Wait for response (up to 5 minutes)
      const response = await waitForResponse(messageId, 300000);

      if (response) {
        updateStatus("in_progress", { resumed_after: "pm_response" });
        return {
          content: [
            {
              type: "text",
              text: `PM Response:\n${response.answer}`
            }
          ]
        };
      } else {
        updateStatus("in_progress", { note: "pm_timeout" });
        return {
          content: [
            {
              type: "text",
              text: "No response received from PM within timeout. Proceeding with best judgment."
            }
          ]
        };
      }
    }

    case "send_status": {
      const { status, message, progress } = args;
      updateStatus(status, { message, progress });

      return {
        content: [
          {
            type: "text",
            text: `Status updated: ${status} - ${message}`
          }
        ]
      };
    }

    case "get_messages": {
      const { unreadOnly = true } = args;
      const inbox = readJsonFile(INBOX_FILE);

      let messages = inbox.messages.filter(m => m.to === AGENT_ID || m.to === "all");

      if (unreadOnly) {
        messages = messages.filter(m => !m.read);
      }

      // Mark as read
      if (messages.length > 0) {
        inbox.messages = inbox.messages.map(m => {
          if (messages.find(msg => msg.id === m.id)) {
            return { ...m, read: true };
          }
          return m;
        });
        writeJsonFile(INBOX_FILE, inbox);
      }

      return {
        content: [
          {
            type: "text",
            text: messages.length > 0
              ? `You have ${messages.length} message(s):\n\n${messages.map(m => `From ${m.from}: ${m.message || m.answer}`).join('\n\n')}`
              : "No new messages."
          }
        ]
      };
    }

    case "notify_pm": {
      const { message, type = "info" } = args;
      const outbox = readJsonFile(OUTBOX_FILE);

      outbox.messages.push({
        id: crypto.randomUUID(),
        from: AGENT_ID,
        task: TASK_ID,
        to: "pm",
        type: "notification",
        notificationType: type,
        message: message,
        timestamp: new Date().toISOString()
      });

      writeJsonFile(OUTBOX_FILE, outbox);

      return {
        content: [
          {
            type: "text",
            text: `Notification sent to PM: [${type.toUpperCase()}] ${message}`
          }
        ]
      };
    }

    case "task_complete": {
      const { summary, files_changed = [] } = args;

      // Notify PM of completion
      const outbox = readJsonFile(OUTBOX_FILE);
      outbox.messages.push({
        id: crypto.randomUUID(),
        from: AGENT_ID,
        task: TASK_ID,
        to: "pm",
        type: "task_complete",
        summary: summary,
        filesChanged: files_changed,
        timestamp: new Date().toISOString(),
        status: "pending"  // Required for orchestrator to process
      });
      writeJsonFile(OUTBOX_FILE, outbox);

      // Update status
      updateStatus("completed", { summary, files_changed });
      updateAgentPool("completed", TASK_ID);

      return {
        content: [
          {
            type: "text",
            text: `Task ${TASK_ID} marked complete. Summary: ${summary}\nYou can now call await_assignment() to get a new task.`
          }
        ]
      };
    }

    case "await_assignment": {
      const { capabilities = [] } = args;

      // Register in pool with capabilities
      registerAgent(AGENT_ID.split('-')[0], capabilities);

      // Wait for assignment
      const assignment = await waitForAssignment(600000); // 10 min timeout

      if (assignment) {
        return {
          content: [
            {
              type: "text",
              text: `NEW ASSIGNMENT RECEIVED!\n\nTask ID: ${assignment.taskId}\nBranch: ${assignment.branch}\nType: ${assignment.type}\n\nDescription:\n${assignment.description}\n\nStart working on this task now.`
            }
          ]
        };
      } else {
        // Timeout - agent should exit
        updateAgentPool("terminated", null);
        return {
          content: [
            {
              type: "text",
              text: "No new assignment received within timeout. You may now exit gracefully."
            }
          ]
        };
      }
    }

    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

// Start server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Orchestrator Messaging MCP Server running");
}

main().catch(console.error);
