# ResQMesh Global Relay Server

A lightweight real-time server that acts as the internet backbone for the ResQMesh emergency mesh network.

## Quick Start

```bash
# Install dependencies
npm install

# Start server
npm start

# Dev mode (auto-restart on file changes)
npm run dev
```

## Find Your LAN IP (to configure the mobile app)

**Windows:**
```
ipconfig
```
Look for `IPv4 Address` under your Wi-Fi adapter — e.g. `192.168.1.42`

**Then update this line in the Flutter app:**
```
resqmesh_mobile/lib/services/gateway_service.dart

static const String _serverUrl = 'http://192.168.1.42:3000';
```

## API Reference

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/status` | Server health, connected phone count |
| `GET` | `/api/alerts` | Last 50 alerts in memory |
| `POST` | `/api/alert` | Upload a new SOS alert from a phone |
| `WS` | `socket 'send_alert'` | Phone sends alert via WebSocket |
| `WS` | `socket 'new_alert'` | Server pushes alert to all phones |
| `WS` | `socket 'alert_history'` | Sent once when phone first connects |

## How It Fits in the System

```
Village (no internet)          Nearest phone with 4G     ResQMesh Server
──────────────────────         ─────────────────────     ───────────────
Phone A: sends SOS
  │
  └─ BT mesh relay ──────────► Phone B (bridge)
                                  │
                                  └─ POST /api/alert ──► server.js
                                                            │
                                                            └─ Socket.IO broadcast
                                                                  │
                                                                  ├─► Phone C (city)
                                                                  ├─► Phone D (city)
                                                                  └─► Phone E (city)
```

## Cloud Deployment (Optional)

Deploy to Render.com for free:

1. Push `resqmesh_server/` to a GitHub repo
2. Create a new Web Service on [render.com](https://render.com)
3. Set start command: `node server.js`
4. Update `_serverUrl` in `gateway_service.dart` to the Render URL
