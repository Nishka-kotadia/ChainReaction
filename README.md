<div align="center">

# 🔴 ResQMesh

### *Emergency Communication That Works When Everything Else Fails*

**A decentralised, offline-first disaster response platform powered by Bluetooth mesh networking and on-device AI.**

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Node.js](https://img.shields.io/badge/Node.js-20.x-339933?logo=node.js&logoColor=white)](https://nodejs.org)
[![Socket.IO](https://img.shields.io/badge/Socket.IO-4.x-010101?logo=socket.io&logoColor=white)](https://socket.io)
[![ONNX Runtime](https://img.shields.io/badge/ONNX_Runtime-1.x-005CED?logo=onnx&logoColor=white)](https://onnxruntime.ai)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

*Built for hackathons · Runs without internet · Saves lives*

</div>

---

## 🌍 The Problem

When a disaster strikes — earthquake, flood, wildfire — the **first thing that fails is communication infrastructure**. Cell towers collapse. Internet goes down. Emergency services are overwhelmed. People are left without a way to call for help, and first responders have no situational awareness.

**ResQMesh solves this.**

---

## 💡 What Is ResQMesh?

ResQMesh is a **hybrid emergency coordination system** that creates an automatic, self-healing communication network from the phones already in people's pockets. It works in three modes simultaneously:

| Mode | How It Works | Range |
|---|---|---|
| 🔵 **Bluetooth Mesh** | Phones form a P2P cluster via Google Nearby Connections. Each phone relays alerts to the next. | ~100m per hop, unlimited chain depth |
| 🌐 **Cloud Gateway** | Any phone with internet automatically uplinks alerts to a global server, bridging mesh islands. | Global |
| 📵 **Fully Offline** | When there's no internet and no Bluetooth peers, GPS and local AI still function for triage. | Local device |

> Think of it as a **chain reaction** — one person triggers an SOS, and it propagates through every nearby phone like a digital relay race, until it reaches the cloud or every device in range.

---

## ✨ Core Features

### 🔗 Chain Reaction Mesh Protocol
- Every device simultaneously **advertises** and **discovers** peers via Bluetooth (Google Nearby Connections — P2P\_CLUSTER strategy)
- An alert originates from one device and automatically **relays hop-by-hop** through the entire mesh
- Each relay increments `hopCount`, decrements `TTL` (Time-To-Live, default 15), and appends the relay node to an **immutable audit trail** (`relayPath`)
- **Deduplication engine** ensures no alert is processed twice, preventing infinite relay loops
- Alerts that reach TTL=0 are silently dropped — the chain terminates naturally
- A **discovery watchdog** periodically refreshes Bluetooth scanning to find new nodes joining the mesh

### 🤖 On-Device AI Triage Engine
- A **keyword-priority NLP rules engine** classifies every emergency description in under 1ms
- Detects 25+ emergency scenarios: cardiac arrest, drowning, fire, explosion, flooding, trapped victims, missing persons, earthquakes, and more
- Outputs structured `TriageResult`: `severity` (Low / Medium / High / Critical), `alertType`, and an **actionable first-aid instruction**
- Runs **entirely on-device**, no internet required, no API calls, no latency

### 📸 Offline Image-Based Verification
- Users can **attach a photo** (camera or gallery) to their SOS report
- **Google ML Kit Image Labeling** runs locally on the device to extract emergency scene tags (Fire, Smoke, Flood, Person, etc.)
- A custom **MobileNetV3-INT8 ONNX model** performs disaster scene classification to verify the image matches an actual emergency
- Detected labels are automatically appended to the alert description and fed into the triage engine

### 🛡️ Anti-False-Alarm Guard (`DisasterVerifier`)
- Every SOS must pass a **verification gate** before it can be broadcast
- Text is checked against emergency keyword lists and non-emergency phrase blocklists
- If the text triage score is below `Medium` severity, the broadcast is **blocked with a user-friendly message**
- Optionally verified by the on-device ONNX classifier — prevents accidental emergency broadcasts

### 🌐 Internet Gateway Bridge
- `GatewayService` monitors connectivity in real-time using `connectivity_plus`
- On internet detection, it **automatically connects** to the global relay server via WebSocket (Socket.IO)
- Uplinks local mesh alerts to the server; downlinks global alerts into the local Bluetooth mesh
- Falls back to HTTP POST if the WebSocket connection is not yet established
- Server URL is **configurable at runtime** from a settings screen — no app rebuild needed

### 📍 Live Location Tracking & Mesh Map
- Every device broadcasts its GPS position to all connected peers **every 5 seconds**
- Locations propagate multi-hop through the mesh — even devices with no internet are visible on the map of internet-connected devices
- Server maintains a **location cache** and sends a snapshot to every newly-connecting phone
- The interactive map (OpenStreetMap via `flutter_map`) shows **all active mesh nodes and emergency pins** in real-time
- Map tiles are **cached offline** so the map remains visible even after internet loss

### 📋 Chain Relay Log
- A dedicated **Chain Log tab** records every relay event: which node received an alert, from whom, and at what hop number
- Provides full observability into the mesh propagation — valuable for incident reconstruction

### 🔔 Push Notifications
- `flutter_local_notifications` fires a device notification for every incoming alert from other mesh nodes
- Alerts you even when the app is backgrounded

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        DEVICE A (Origin)                        │
│  [User types SOS] → [AI Triage] → [DisasterVerifier] → [Alert] │
│       ↓ Bluetooth                        ↓ Internet             │
│  MeshService                       GatewayService               │
│  (P2P_CLUSTER)                     (Socket.IO / HTTP)           │
└───────────┬────────────────────────────────┬────────────────────┘
            │ BT                             │ WS/HTTP
            ▼                               ▼
┌───────────────────┐            ┌──────────────────────────┐
│    DEVICE B        │            │   ResQMesh Global Server  │
│  [Relay + Forward] │            │   Node.js + Express       │
│  to Device C, D…  │            │   + Socket.IO             │
└───────────────────┘            │   (Render / Railway)      │
            │ BT                 └──────────┬───────────────┘
            ▼                              │ WS Broadcast
┌───────────────────┐                      ▼
│    DEVICE C        │          ┌──────────────────────────┐
│  [Relay + Forward] │          │  ALL CONNECTED DEVICES    │
│  (no internet)     │          │  receive alert globally   │
└───────────────────┘          └──────────────────────────┘
```

### Key Protocol Properties
- **Self-healing**: If a relay node disappears, other paths in the mesh continue
- **Dedup-safe**: Alert IDs are tracked in a `Set<String>` — processing each ID exactly once
- **Bridge-capable**: Internet-connected phones automatically bridge mesh islands to the global network
- **Resolution propagation**: When the emergency creator resolves an alert, a resolution packet traverses the full mesh (TTL resets to 15) and all devices remove the alert from their dashboard

---

## 📦 Repository Structure

```
Chain_Reaction/
├── resqmesh_mobile/        # Flutter Android app
│   ├── lib/
│   │   ├── main.dart               # App entry, service wiring
│   │   ├── services/
│   │   │   ├── mesh_service.dart   # Bluetooth mesh + chain reaction engine
│   │   │   ├── gateway_service.dart# Internet bridge (Socket.IO + HTTP)
│   │   │   ├── ai_triage.dart      # On-device NLP triage + ML Kit image scan
│   │   │   ├── disaster_verifier.dart # ONNX-based SOS verification gate
│   │   │   ├── location_service.dart  # GPS tracking
│   │   │   ├── cached_tile_provider.dart # Offline map tile cache
│   │   │   ├── notification_service.dart # Push notifications
│   │   │   └── models.dart         # Alert, MeshNode, UserLocation data models
│   │   └── ui/
│   │       ├── home_screen.dart    # Main UI: Dashboard, SOS, Map, Chain Log
│   │       └── server_settings_screen.dart # Runtime server URL config
│   └── assets/
│       └── models/
│           └── disaster_mobilenetv3/  # INT8-quantized ONNX disaster classifier
│               ├── disaster_mobilenetv3_int8.onnx
│               └── disaster_mobilenetv3_metadata.json
│
├── resqmesh_server/        # Node.js global relay server
│   ├── server.js           # Express + Socket.IO server
│   ├── package.json
│   └── .env.example
│
├── resqmesh_mock/          # Static mock dashboard (HTML)
│   └── index.html
│
└── flutter_models/         # ONNX model library + integration docs
    ├── README.md
    └── disaster_mobilenetv3/
```

---

## 🛠️ Tech Stack

### 📱 Mobile App (Flutter)

| Category | Technology | Purpose |
|---|---|---|
| **Framework** | Flutter 3.x (Dart) | Cross-platform mobile app |
| **State Management** | Provider 6.x | Reactive service state across UI |
| **Mesh Networking** | `nearby_connections` 4.x | Google Nearby Connections — BT P2P mesh |
| **Internet Bridge** | `socket_io_client` 2.x | Real-time WebSocket to global server |
| **HTTP** | `http` 1.x | Fallback alert uplink |
| **Connectivity** | `connectivity_plus` 6.x | Network state monitoring |
| **GPS** | `geolocator` 10.x | High-accuracy location tracking |
| **Maps** | `flutter_map` 6.x | OpenStreetMap-based interactive map |
| **AI (NLP)** | Custom rules engine | On-device zero-latency triage |
| **AI (Vision)** | `google_mlkit_image_labeling` | Offline image scene understanding |
| **AI (ONNX)** | `onnxruntime` 1.x | On-device MobileNetV3 disaster classifier |
| **Image Processing** | `image` 4.x | ONNX pre-processing pipeline |
| **Notifications** | `flutter_local_notifications` 18.x | Emergency push alerts |
| **Permissions** | `permission_handler` 11.x | Runtime BT/location permissions |
| **Storage** | `shared_preferences` 2.x | Persistent server URL config |
| **Image Input** | `image_picker` 1.x | Camera & gallery SOS photo capture |

### 🖥️ Backend Server (Node.js)

| Technology | Purpose |
|---|---|
| **Node.js 20.x** | Server runtime |
| **Express 4.x** | HTTP REST API |
| **Socket.IO 4.x** | Real-time bidirectional WebSocket relay |
| **CORS** | Cross-origin request handling |
| **In-memory store** | Alert history buffer (last 100 alerts, no DB needed) |
| **Render / Railway** | Cloud deployment |

### 🧠 AI Models

| Model | Architecture | Size | Task |
|---|---|---|---|
| **disaster_mobilenetv3_int8** | MobileNetV3 (INT8 quantized) | ~1.2 MB | Disaster scene classification for SOS verification |
| **NLP Rules Engine** | Keyword priority matcher | < 1 KB | Emergency triage: type, severity, action |
| **Google ML Kit** | On-device image labeler | Device runtime | Scene object detection from SOS photos |

---

## 🚀 Getting Started

### Prerequisites
- Flutter SDK ≥ 3.0.0
- Android SDK (API 21+)
- Node.js ≥ 18.x
- Two or more Android devices for mesh testing

---

### 1. Clone the Repository

```bash
git clone https://github.com/Nishka-kotadia/ChainReaction.git
cd ChainReaction
```

---

### 2. Run the Global Relay Server

The server is already deployed at:
```
https://server-chain-reaction.onrender.com
```

To run your own instance locally:

```bash
cd resqmesh_server
npm install
cp .env.example .env
npm run dev          # Development with auto-reload
# or
npm start            # Production
```

The server exposes:

| Endpoint | Method | Description |
|---|---|---|
| `/api/alert` | POST | Receive and broadcast an SOS alert |
| `/api/alerts` | GET | Fetch last 50 alerts |
| `/api/locations` | GET | Fetch all cached device locations |
| `/api/status` | GET | Health check + connected client count |
| `ws://` | WebSocket | Real-time alert + location relay |

---

### 3. Build & Run the Flutter App

```bash
cd resqmesh_mobile
flutter pub get
flutter run                    # Debug build on connected device
flutter build apk --release   # Production APK
```

> **Important:** The app requires an Android device (not an emulator) for Bluetooth mesh functionality. Two or more physical devices are needed to test the chain relay.

---

### 4. Configure the Server URL (Optional)

The app defaults to the public deployed server. To point it at your own:

1. Open the app → tap the **⚙️ Settings** icon in the top-right
2. Enter your server URL (e.g. `http://192.168.1.10:3000` for LAN, or your deployed URL)
3. The app reconnects immediately — no restart needed

---

## 📱 App Walkthrough

### Tab 1 — Dashboard
- Live status card: mesh ON/OFF, connected Bluetooth peers, total chain relays, global cloud connection
- Feed of all active emergency alerts received from the mesh or cloud
- Each card shows: severity badge, alert type, description, AI-generated action, hop count, TTL remaining
- Alert **originator can resolve** any emergency — resolution propagates through the full mesh

### Tab 2 — SOS (Emergency Broadcast)
1. Type a description of the emergency (e.g. *"There is a fire and someone is trapped under debris"*)
2. Optionally **attach a photo** — the offline AI vision scanner analyses it and appends detected scene tags
3. Edge AI triages the input instantly, showing severity, type, and recommended action
4. The **DisasterVerifier** checks it passes the anti-false-alarm gate
5. Hit **BROADCAST** — the alert fires into Bluetooth peers AND the cloud simultaneously

### Tab 3 — Map
- Interactive OpenStreetMap showing your GPS position
- Pins for all mesh nodes with known GPS coordinates
- Emergency alert pins for all received alerts
- Works offline with cached tiles

### Tab 4 — Chain Log
- Full relay history: from node → to node, hop number, timestamp
- Visualises how an alert propagated through the mesh

---

## 🔒 Privacy & Security

- **No accounts required.** Each device auto-generates a temporary random node ID on launch.
- **No personal data stored.** GPS coordinates are ephemeral — only kept in memory, never written to disk.
- **Open Bluetooth.** Any ResQMesh device automatically connects to any other — intentional for disaster scenarios where you need maximum connectivity.
- **Anti-spam.** The DisasterVerifier gate prevents accidental or malicious false SOS broadcasts.

---

## 🧪 Testing the Mesh

To observe the chain reaction in action:

1. Install the app on **3+ Android phones**
2. Place them within Bluetooth range (~10m for reliable testing)
3. Tap the **Bluetooth icon** on all devices to activate the mesh
4. Watch the dashboard — all devices should show each other as connected nodes
5. From one device, type an SOS in the SOS tab and hit Broadcast
6. **Observe**: all other devices receive the alert within seconds, showing hop count incrementing as the chain propagates

---

## 🌐 Deployment

The global relay server is deployed on **Render** (free tier):

```
https://server-chain-reaction.onrender.com
```

To deploy your own:

```bash
# Render / Railway / Fly.io
# Set environment variable:
PORT=3000

# The Procfile is already included:
web: node server.js
```

---

## 🏆 Hackathon Highlights

| What We Built | Why It Matters |
|---|---|
| Infrastructure-free emergency mesh | Works when cell towers and internet are down |
| Sub-1ms on-device AI triage | Zero latency, zero cloud dependency for critical decisions |
| Anti-false-alarm ONNX gate | Reduces emergency service strain from accidental alerts |
| Automatic cloud bridge | Internet-connected phones silently relay for offline peers |
| Alert resolution propagation | First responders can close emergencies mesh-wide |
| Live peer location tracking | Situational awareness without a central server |
| Offline map with tile caching | Maps work even after losing internet mid-disaster |

---

## 👥 Team

**Chain Reaction** — built at [Hackathon Name]

---

## 📄 License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

---

<div align="center">

*"In a disaster, the most important network is the one that still works."*

**ResQMesh — Because emergencies don't wait for Wi-Fi.**

</div>
