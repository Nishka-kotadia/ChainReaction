// ================================================================
// ResQMesh Global Relay Server
// Stack: Node.js + Express + Socket.IO
//
// RESPONSIBILITIES:
//   1. Accept alert POSTs from any phone with internet (HTTP)
//   2. Track all connected phone WebSockets
//   3. Instantly broadcast every alert to ALL connected phones
//   4. Serve alert history to newly joining phones
//
// ENDPOINTS:
//   POST /api/alert       — phone uploads an SOS alert
//   GET  /api/alerts      — phone fetches history on connect
//   GET  /api/status      — health check / connected count
//   WS   socket 'connect' — phone registers as a live listener
//   WS   socket 'new_alert' — server pushes alert to all phones
// ================================================================

const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const cors = require('cors');

const app = express();
const httpServer = http.createServer(app);

// ── Socket.IO setup ───────────────────────────────────────────
// Allow connections from any origin (phones on different networks)
const io = new Server(httpServer, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST'],
  },
  // Increase ping timeout for unstable mobile connections
  pingTimeout: 30000,
  pingInterval: 10000,
});

// ── Middleware ────────────────────────────────────────────────
app.use(cors());
app.use(express.json());
app.use(express.static('public'));

// ── In-Memory State ───────────────────────────────────────────
// Stores last MAX_ALERTS alerts. No database needed for hackathon.
const MAX_ALERTS = 100;
const alertHistory = [];

// Track connected clients: socketId → { nodeId, connectedAt }
const connectedClients = new Map();

// ── Location Cache (userId → latest location) ─────────────────
// Keeps last known position for every user so late-joining phones
// immediately see all active users on the map.
const locationCache = new Map();

// ── Utility ───────────────────────────────────────────────────
function logWithTime(msg) {
  const time = new Date().toISOString().replace('T', ' ').split('.')[0];
  console.log(`[${time}] ${msg}`);
}

function storeAlert(alert) {
  // Dedup: don't store the same alert ID twice
  const existingIdx = alertHistory.findIndex(a => a.id === alert.id);
  if (existingIdx !== -1) {
    if (alert.isResolved && !alertHistory[existingIdx].isResolved) {
      alertHistory[existingIdx].isResolved = true;
      return true; // Return true so the resolution is broadcasted
    }
    return false;
  }

  // Add server receipt metadata
  alert._receivedAt = new Date().toISOString();
  alert._source = 'gateway';

  alertHistory.push(alert);

  // Keep buffer trimmed
  if (alertHistory.length > MAX_ALERTS) {
    alertHistory.shift();
  }

  return true;
}

// ================================================================
// HTTP ROUTES
// ================================================================

// Health check — shows server is alive and how many phones connected
app.get('/api/status', (req, res) => {
  res.json({
    status: 'online',
    connectedClients: connectedClients.size,
    totalAlertsRelayed: alertHistory.length,
    uptime: Math.floor(process.uptime()) + 's',
    clients: Array.from(connectedClients.values()),
  });
});

// Phone fetches recent alert history when it first connects
app.get('/api/alerts', (req, res) => {
  res.json({
    count: alertHistory.length,
    alerts: alertHistory.slice(-50), // Last 50 only
  });
});

// ── MAIN ENDPOINT: Phone uploads an alert ─────────────────────
app.post('/api/alert', (req, res) => {
  const alert = req.body;

  // Basic validation
  if (!alert || !alert.id || !alert.description) {
    return res.status(400).json({ error: 'Invalid alert payload. id and description required.' });
  }

  const isNew = storeAlert(alert);

  if (isNew) {
    logWithTime(`🆘 NEW ALERT [${alert.id.substring(0, 8)}...] type=${alert.alertType} from nodeId=${alert.originNodeId} hop=${alert.hopCount}`);

    // Broadcast to ALL connected phones via WebSocket immediately
    io.emit('new_alert', alert);

    logWithTime(`📡 Broadcasted to ${connectedClients.size} connected phone(s)`);

    return res.status(201).json({
      success: true,
      message: 'Alert stored and broadcasted',
      broadcastedTo: connectedClients.size,
    });
  } else {
    logWithTime(`🔁 DUPLICATE alert [${alert.id.substring(0, 8)}...] ignored`);
    return res.status(200).json({
      success: false,
      message: 'Duplicate alert — already in history',
    });
  }
});

// GET all cached locations (HTTP fallback)
app.get('/api/locations', (req, res) => {
  res.json({
    count: locationCache.size,
    locations: Array.from(locationCache.values()),
  });
});

// ================================================================
// WEBSOCKET — Real-time phone connections
// ================================================================

io.on('connection', (socket) => {
  const nodeId = socket.handshake.query.nodeId || `unknown_${socket.id}`;

  connectedClients.set(socket.id, {
    nodeId,
    connectedAt: new Date().toISOString(),
    socketId: socket.id,
  });

  logWithTime(`🟢 PHONE CONNECTED: nodeId=${nodeId} (${connectedClients.size} total)`);

  // Send recent history immediately so the newly connected phone is up to date
  if (alertHistory.length > 0) {
    socket.emit('alert_history', alertHistory.slice(-20));
    logWithTime(`📜 Sent ${Math.min(alertHistory.length, 20)} historical alerts to ${nodeId}`);
  }

  // Notify all other phones that a new node joined (optional UI feature)
  socket.broadcast.emit('node_joined', { nodeId, totalConnected: connectedClients.size });

  // ── Phone sends an alert directly via WebSocket (alternative to HTTP POST) ──
  socket.on('send_alert', (alert) => {
    if (!alert || !alert.id) return;

    const isNew = storeAlert(alert);
    if (isNew) {
      logWithTime(`⚡ WS ALERT [${alert.id.substring(0, 8)}...] from ${nodeId} → broadcasting to ${connectedClients.size - 1} other(s)`);
      // Broadcast to everyone EXCEPT the sender (they already have it)
      socket.broadcast.emit('new_alert', alert);
    }
  });

  // ── Phone sends a location update directly via WebSocket ──────
  socket.on('location_update', (location) => {
    if (!location || !location.userId) return;

    // Update server-side location cache
    locationCache.set(location.userId, location);

    // Broadcast to everyone EXCEPT the sender
    socket.broadcast.emit('location_update', location);
  });

  // ── Send all cached locations when a new phone connects ───────
  if (locationCache.size > 0) {
    const allLocations = Array.from(locationCache.values());
    socket.emit('location_snapshot', allLocations);
    logWithTime(`📍 Sent ${allLocations.length} cached location(s) to new client ${nodeId}`);
  }

  // ── Phone disconnects ─────────────────────────────────────────
  socket.on('disconnect', (reason) => {
    connectedClients.delete(socket.id);
    logWithTime(`🔴 PHONE DISCONNECTED: nodeId=${nodeId} reason=${reason} (${connectedClients.size} remaining)`);
    io.emit('node_left', { nodeId, totalConnected: connectedClients.size });
  });
});

// ================================================================
// START SERVER
// ================================================================
const PORT = process.env.PORT || 3000;

httpServer.listen(PORT, '0.0.0.0', () => {
  logWithTime(`✅ ResQMesh Server running on port ${PORT}`);
  logWithTime(`📡 HTTP  → POST http://YOUR_IP:${PORT}/api/alert`);
  logWithTime(`📡 HTTP  → GET  http://YOUR_IP:${PORT}/api/status`);
  logWithTime(`🔌 WS    → ws://YOUR_IP:${PORT}`);
  logWithTime('');
  logWithTime('Replace YOUR_IP with your LAN IP (e.g. 192.168.1.X)');
  logWithTime('Run: ipconfig (Windows) or ifconfig (Mac/Linux) to find it');
});
