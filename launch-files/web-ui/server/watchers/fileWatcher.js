import chokidar from 'chokidar';
import fs from 'fs';
import path from 'path';

// Debounce helper to prevent rapid-fire events
function debounce(fn, delay) {
  let timeout;
  return (...args) => {
    clearTimeout(timeout);
    timeout = setTimeout(() => fn(...args), delay);
  };
}

// Read JSON file safely
function readJsonFile(filePath) {
  try {
    if (fs.existsSync(filePath)) {
      const content = fs.readFileSync(filePath, 'utf-8');
      return JSON.parse(content);
    }
  } catch (e) {
    // File might be being written
    console.error(`Error reading ${filePath}:`, e.message);
  }
  return null;
}

// Parse status file (key: value format)
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

// Get all project directories
function getProjectDirs(projectsDir) {
  try {
    if (!fs.existsSync(projectsDir)) return [];
    return fs.readdirSync(projectsDir)
      .filter(f => fs.statSync(path.join(projectsDir, f)).isDirectory())
      .map(f => path.join(projectsDir, f));
  } catch (e) {
    return [];
  }
}

export function setupFileWatchers({ RUNTIME_DIR, PROJECTS_DIR, STATUS_DIR, broadcast }) {
  console.log('Setting up file watchers...');

  // Watch patterns
  const watchPatterns = [
    // Watch all project status directories
    path.join(PROJECTS_DIR, '*/status/tasks.json'),
    path.join(PROJECTS_DIR, '*/status/*.status'),
    path.join(PROJECTS_DIR, '*/status/*.completed'),
    path.join(PROJECTS_DIR, '*/status/*.approved'),
    path.join(PROJECTS_DIR, '*/status/messages/*.json'),
    // Also watch legacy single-project paths
    path.join(STATUS_DIR, 'tasks.json'),
    path.join(STATUS_DIR, '*.status'),
    path.join(STATUS_DIR, '*.completed'),
    path.join(STATUS_DIR, '*.approved'),
    path.join(STATUS_DIR, 'messages/*.json'),
  ];

  const watcher = chokidar.watch(watchPatterns, {
    persistent: true,
    ignoreInitial: true,
    awaitWriteFinish: {
      stabilityThreshold: 300,
      pollInterval: 100
    }
  });

  // Handle file changes with debouncing
  const handleChange = debounce((eventType, filePath) => {
    console.log(`File ${eventType}: ${filePath}`);

    const filename = path.basename(filePath);
    const dirname = path.dirname(filePath);

    // Extract project name from path
    const projectMatch = filePath.match(/projects\/([^/]+)\//);
    const projectName = projectMatch ? projectMatch[1] : 'default';

    // Determine event type based on file
    if (filename === 'tasks.json') {
      const tasks = readJsonFile(filePath);
      if (tasks) {
        broadcast({
          type: 'tasks:update',
          project: projectName,
          tasks: tasks.tasks || [],
          timestamp: new Date().toISOString()
        });
      }
    } else if (filename.endsWith('.status')) {
      const taskId = filename.replace('.status', '');
      const status = parseStatusFile(filePath);
      if (status) {
        broadcast({
          type: 'task:running',
          project: projectName,
          taskId,
          status,
          timestamp: new Date().toISOString()
        });
      }
    } else if (filename.endsWith('.completed')) {
      const taskId = filename.replace('.completed', '');
      const status = parseStatusFile(filePath);
      broadcast({
        type: 'task:completed',
        project: projectName,
        taskId,
        status,
        timestamp: new Date().toISOString()
      });
    } else if (filename.endsWith('.approved')) {
      const taskId = filename.replace('.approved', '');
      const status = parseStatusFile(filePath);
      broadcast({
        type: 'task:approved',
        project: projectName,
        taskId,
        status,
        timestamp: new Date().toISOString()
      });
    } else if (filename === 'outbox.json') {
      // Check for new PM questions
      const outbox = readJsonFile(filePath);
      if (outbox && outbox.messages) {
        const pendingQuestions = outbox.messages.filter(
          m => m.status === 'pending' && m.to === 'pm'
        );
        // Also check for escalations to user
        const userEscalations = outbox.messages.filter(
          m => m.status === 'pending' && m.to === 'user'
        );
        if (userEscalations.length > 0) {
          for (const msg of userEscalations) {
            broadcast({
              type: 'pm:question',
              project: projectName,
              message: msg,
              timestamp: new Date().toISOString()
            });
          }
        }
        // Send agent questions for activity log
        if (pendingQuestions.length > 0) {
          broadcast({
            type: 'agent:messages',
            project: projectName,
            messages: pendingQuestions,
            timestamp: new Date().toISOString()
          });
        }
      }
    } else if (filename === 'status.json') {
      // Agent status updates
      const status = readJsonFile(filePath);
      if (status && status.agents) {
        broadcast({
          type: 'agents:status',
          project: projectName,
          agents: status.agents,
          timestamp: new Date().toISOString()
        });
      }
    } else if (filename === 'agent_pool.json') {
      // Agent pool updates
      const pool = readJsonFile(filePath);
      if (pool && pool.agents) {
        broadcast({
          type: 'pool:update',
          project: projectName,
          agents: pool.agents,
          timestamp: new Date().toISOString()
        });
      }
    } else if (filename === 'inbox.json') {
      // Responses from PM
      const inbox = readJsonFile(filePath);
      if (inbox && inbox.messages) {
        broadcast({
          type: 'inbox:update',
          project: projectName,
          messages: inbox.messages,
          timestamp: new Date().toISOString()
        });
      }
    }
  }, 200);

  watcher.on('add', (path) => handleChange('added', path));
  watcher.on('change', (path) => handleChange('changed', path));
  watcher.on('unlink', (path) => {
    console.log(`File removed: ${path}`);
    const filename = path.basename(path);
    const projectMatch = path.match(/projects\/([^/]+)\//);
    const projectName = projectMatch ? projectMatch[1] : 'default';

    // Status file removed = task no longer running
    if (filename.endsWith('.status')) {
      const taskId = filename.replace('.status', '');
      broadcast({
        type: 'task:stopped',
        project: projectName,
        taskId,
        timestamp: new Date().toISOString()
      });
    }
  });

  watcher.on('error', (error) => {
    console.error('Watcher error:', error);
  });

  watcher.on('ready', () => {
    console.log('File watchers ready');
  });

  return watcher;
}
