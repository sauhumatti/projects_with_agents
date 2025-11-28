import express from 'express';
import fs from 'fs';
import path from 'path';
import { v4 as uuidv4 } from 'uuid';

const router = express.Router();

// Helper to read JSON file safely
function readJsonFile(filePath) {
  try {
    if (fs.existsSync(filePath)) {
      return JSON.parse(fs.readFileSync(filePath, 'utf-8'));
    }
  } catch (e) {
    console.error(`Error reading ${filePath}:`, e.message);
  }
  return null;
}

// Helper to write JSON file atomically
function writeJsonFile(filePath, data) {
  const tmpPath = filePath + '.tmp';
  fs.writeFileSync(tmpPath, JSON.stringify(data, null, 2));
  fs.renameSync(tmpPath, filePath);
}

// Helper to parse status files
function parseStatusFile(filePath) {
  try {
    if (fs.existsSync(filePath)) {
      const content = fs.readFileSync(filePath, 'utf-8');
      const result = {};
      for (const line of content.split('\n')) {
        const [key, ...valueParts] = line.split(':');
        if (key && valueParts.length) {
          result[key.trim()] = valueParts.join(':').trim();
        }
      }
      return result;
    }
  } catch (e) {
    console.error(`Error parsing ${filePath}:`, e.message);
  }
  return null;
}

// Get project status directory
function getProjectStatusDir(req, projectName) {
  const { PROJECTS_DIR, STATUS_DIR } = req.app.locals;

  // Check if it's a project in the projects dir
  const projectStatusDir = path.join(PROJECTS_DIR, projectName, 'status');
  if (fs.existsSync(projectStatusDir)) {
    return projectStatusDir;
  }

  // Fall back to legacy single status dir
  return STATUS_DIR;
}

// List all projects
router.get('/projects', (req, res) => {
  const { PROJECTS_DIR } = req.app.locals;

  try {
    if (!fs.existsSync(PROJECTS_DIR)) {
      return res.json({ projects: [] });
    }

    const projects = fs.readdirSync(PROJECTS_DIR)
      .filter(f => fs.statSync(path.join(PROJECTS_DIR, f)).isDirectory())
      .map(name => {
        const projectDir = path.join(PROJECTS_DIR, name);
        const projectJson = path.join(projectDir, 'project.json');
        const tasksJson = path.join(projectDir, 'status', 'tasks.json');

        let info = { name };

        // Read project.json
        const projectData = readJsonFile(projectJson);
        if (projectData) {
          info.description = projectData.description;
          info.created = projectData.created;
          info.projectStatus = projectData.status;
        }

        // Read tasks.json for task counts
        const tasksData = readJsonFile(tasksJson);
        if (tasksData && tasksData.tasks) {
          info.totalTasks = tasksData.tasks.length;
          info.completedTasks = tasksData.tasks.filter(
            t => t.status === 'completed'
          ).length;
        }

        return info;
      });

    res.json({ projects });
  } catch (e) {
    console.error('Error listing projects:', e);
    res.status(500).json({ error: e.message });
  }
});

// Get project details
router.get('/projects/:name', (req, res) => {
  const { PROJECTS_DIR } = req.app.locals;
  const { name } = req.params;

  const projectDir = path.join(PROJECTS_DIR, name);
  const projectJson = path.join(projectDir, 'project.json');

  const projectData = readJsonFile(projectJson);
  if (!projectData) {
    return res.status(404).json({ error: 'Project not found' });
  }

  res.json(projectData);
});

// Get tasks for a project
router.get('/tasks', (req, res) => {
  const { project } = req.query;

  if (!project) {
    return res.status(400).json({ error: 'project parameter required' });
  }

  const statusDir = getProjectStatusDir(req, project);
  const tasksFile = path.join(statusDir, 'tasks.json');
  const tasksData = readJsonFile(tasksFile);

  if (!tasksData) {
    return res.json({ tasks: [] });
  }

  // Enhance tasks with status from .status files
  const tasks = (tasksData.tasks || []).map(task => {
    const statusFile = path.join(statusDir, `${task.id}.status`);
    const completedFile = path.join(statusDir, `${task.id}.completed`);
    const approvedFile = path.join(statusDir, `${task.id}.approved`);

    let currentStatus = task.status || 'pending';

    if (fs.existsSync(approvedFile)) {
      currentStatus = 'approved';
    } else if (fs.existsSync(completedFile)) {
      currentStatus = 'completed';
    } else if (fs.existsSync(statusFile)) {
      currentStatus = 'running';
      const statusData = parseStatusFile(statusFile);
      if (statusData) {
        task.runningAgent = statusData.agent;
        task.startedAt = statusData.started;
      }
    }

    return { ...task, currentStatus };
  });

  res.json({ tasks, projectName: tasksData.project_name });
});

// Get agent pool status
router.get('/agents', (req, res) => {
  const { project } = req.query;

  if (!project) {
    return res.status(400).json({ error: 'project parameter required' });
  }

  const statusDir = getProjectStatusDir(req, project);
  const messagesDir = path.join(statusDir, 'messages');

  // Agent pool
  const poolFile = path.join(messagesDir, 'agent_pool.json');
  const poolData = readJsonFile(poolFile);

  // Agent status
  const statusFile = path.join(messagesDir, 'status.json');
  const statusData = readJsonFile(statusFile);

  res.json({
    pool: poolData?.agents || {},
    status: statusData?.agents || {}
  });
});

// Get messages (PM questions for user)
router.get('/messages', (req, res) => {
  const { project, pending } = req.query;

  if (!project) {
    return res.status(400).json({ error: 'project parameter required' });
  }

  const statusDir = getProjectStatusDir(req, project);
  const messagesDir = path.join(statusDir, 'messages');
  const outboxFile = path.join(messagesDir, 'outbox.json');
  const inboxFile = path.join(messagesDir, 'inbox.json');

  const outbox = readJsonFile(outboxFile) || { messages: [] };
  const inbox = readJsonFile(inboxFile) || { messages: [] };

  let messages = outbox.messages || [];

  // Filter for user-directed messages (escalations from PM)
  messages = messages.filter(m => m.to === 'user' || m.escalatedToUser);

  if (pending === 'true') {
    messages = messages.filter(m => m.status === 'pending');
  }

  // Add response status
  messages = messages.map(m => {
    const response = inbox.messages?.find(r => r.replyTo === m.id);
    return {
      ...m,
      hasResponse: !!response,
      response: response?.answer
    };
  });

  res.json({ messages });
});

// User responds to PM question
router.post('/messages/:id/respond', (req, res) => {
  const { id } = req.params;
  const { response, project } = req.body;

  if (!response || !project) {
    return res.status(400).json({ error: 'response and project required' });
  }

  const statusDir = getProjectStatusDir(req, project);
  const messagesDir = path.join(statusDir, 'messages');
  const outboxFile = path.join(messagesDir, 'outbox.json');
  const inboxFile = path.join(messagesDir, 'inbox.json');

  // Update outbox message status
  const outbox = readJsonFile(outboxFile) || { messages: [] };
  const messageIdx = outbox.messages.findIndex(m => m.id === id);

  if (messageIdx === -1) {
    return res.status(404).json({ error: 'Message not found' });
  }

  outbox.messages[messageIdx].status = 'responded';
  writeJsonFile(outboxFile, outbox);

  // Add response to inbox
  const inbox = readJsonFile(inboxFile) || { messages: [] };
  inbox.messages.push({
    id: uuidv4(),
    replyTo: id,
    from: 'user',
    answer: response,
    timestamp: new Date().toISOString(),
    read: false
  });
  writeJsonFile(inboxFile, inbox);

  // Broadcast update
  const { broadcast } = req.app.locals;
  broadcast({
    type: 'user:response',
    project,
    messageId: id,
    timestamp: new Date().toISOString()
  });

  res.json({ success: true });
});

// Get activity log (recent events)
router.get('/logs', (req, res) => {
  const { project, limit = 50 } = req.query;

  if (!project) {
    return res.status(400).json({ error: 'project parameter required' });
  }

  const { PROJECTS_DIR } = req.app.locals;
  const logsDir = path.join(PROJECTS_DIR, project, 'logs');

  const logs = [];

  try {
    if (fs.existsSync(logsDir)) {
      // Read session logs
      const logFiles = fs.readdirSync(logsDir)
        .filter(f => f.startsWith('session_'))
        .sort()
        .reverse()
        .slice(0, 3); // Last 3 session logs

      for (const logFile of logFiles) {
        const content = fs.readFileSync(path.join(logsDir, logFile), 'utf-8');
        const lines = content.split('\n').slice(-100); // Last 100 lines

        for (const line of lines) {
          const match = line.match(/^\[([^\]]+)\] \[([^\]]+)\] (.+)$/);
          if (match) {
            logs.push({
              timestamp: match[1],
              level: match[2],
              message: match[3]
            });
          }
        }
      }
    }
  } catch (e) {
    console.error('Error reading logs:', e);
  }

  // Sort by timestamp and limit
  logs.sort((a, b) => b.timestamp.localeCompare(a.timestamp));
  res.json({ logs: logs.slice(0, parseInt(limit)) });
});

// Get orchestrator status (is it running?)
router.get('/orchestrator/status', (req, res) => {
  const { project } = req.query;

  if (!project) {
    return res.status(400).json({ error: 'project parameter required' });
  }

  const statusDir = getProjectStatusDir(req, project);
  const stateFile = path.join(statusDir, 'orchestrator_state.json');
  const state = readJsonFile(stateFile);

  res.json({
    hasState: !!state,
    state: state || null,
    timestamp: new Date().toISOString()
  });
});

export default router;
