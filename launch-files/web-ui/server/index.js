import express from 'express';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';
import cors from 'cors';
import path from 'path';
import { fileURLToPath } from 'url';

import { setupFileWatchers } from './watchers/fileWatcher.js';
import apiRoutes from './routes/api.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Configuration
const PORT = process.env.PORT || 3001;
const RUNTIME_DIR = process.env.RUNTIME_DIR || path.resolve(__dirname, '../../../runtime');
const PROJECTS_DIR = path.join(RUNTIME_DIR, 'projects');

// For backward compatibility, also support direct status dir
const STATUS_DIR = process.env.STATUS_DIR || path.join(RUNTIME_DIR, 'status');

console.log('Configuration:');
console.log('  RUNTIME_DIR:', RUNTIME_DIR);
console.log('  PROJECTS_DIR:', PROJECTS_DIR);
console.log('  STATUS_DIR:', STATUS_DIR);

// Express app
const app = express();
const server = createServer(app);

// WebSocket server
const wss = new WebSocketServer({ server });

// Connected clients
const clients = new Set();

wss.on('connection', (ws) => {
  console.log('WebSocket client connected');
  clients.add(ws);

  ws.on('message', (message) => {
    try {
      const data = JSON.parse(message);
      handleClientMessage(ws, data);
    } catch (e) {
      console.error('Invalid WebSocket message:', e);
    }
  });

  ws.on('close', () => {
    console.log('WebSocket client disconnected');
    clients.delete(ws);
  });

  // Send initial state
  ws.send(JSON.stringify({ type: 'connected', timestamp: new Date().toISOString() }));
});

// Handle incoming WebSocket messages from clients
function handleClientMessage(ws, data) {
  console.log('Received from client:', data.type);

  switch (data.type) {
    case 'state:refresh':
      // Client requests full state refresh - handled by REST API
      break;
    case 'pm:respond':
      // User responds to PM question - handled by messaging service
      break;
    default:
      console.log('Unknown message type:', data.type);
  }
}

// Broadcast to all connected clients
export function broadcast(event) {
  const message = JSON.stringify(event);
  for (const client of clients) {
    if (client.readyState === 1) { // WebSocket.OPEN
      client.send(message);
    }
  }
}

// Broadcast to single client
export function sendToClient(ws, event) {
  if (ws.readyState === 1) {
    ws.send(JSON.stringify(event));
  }
}

// Middleware
app.use(cors());
app.use(express.json());

// Make directories available to routes
app.locals.RUNTIME_DIR = RUNTIME_DIR;
app.locals.PROJECTS_DIR = PROJECTS_DIR;
app.locals.STATUS_DIR = STATUS_DIR;
app.locals.broadcast = broadcast;

// API routes
app.use('/api', apiRoutes);

// Serve React build in production
if (process.env.NODE_ENV === 'production') {
  const clientBuild = path.join(__dirname, '../client/dist');
  app.use(express.static(clientBuild));
  app.get('*', (req, res) => {
    res.sendFile(path.join(clientBuild, 'index.html'));
  });
}

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Start server
server.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
  console.log(`WebSocket available on ws://localhost:${PORT}`);

  // Set up file watchers
  setupFileWatchers({ RUNTIME_DIR, PROJECTS_DIR, STATUS_DIR, broadcast });
});

export { wss, clients };
