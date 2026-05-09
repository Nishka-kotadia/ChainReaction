import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'gateway_service.dart';
import 'models.dart';
import 'notification_service.dart';

// ============================================================
// ResQMesh — Bluetooth Chain Reaction Mesh Service
//
// CHAIN REACTION PROTOCOL:
//   1. Device A creates an Alert and calls broadcastAlert()
//   2. A sends the payload to ALL directly connected BT peers
//   3. Each peer (B, C, D...) receives it, checks their dedup set
//   4. If NEW: peer increments hopCount, decrements TTL, appends
//      its own ID to relayPath, then re-broadcasts to ITS peers
//      (excluding the one it received from)
//   5. Chain continues until TTL hits 0 or no new peers remain
//   6. Every node keeps a Set<String> of seen alert IDs — if an
//      alert is seen again, it is SILENTLY DROPPED.
//
// KEY ARCHITECTURAL NOTE:
//   The nearby_connections library uses a singleton (Nearby()) with
//   single global callbacks for onPayloadReceived and connection
//   events. This means:
//   - We must route ALL payload events through ONE handler
//   - We track connected endpoints in our own map
//   - acceptConnection() registers the ONE global payload handler;
//     we always use the same lambda so it never gets lost
// ============================================================

class MeshService extends ChangeNotifier {
  // ── Identity ──────────────────────────────────────────────
  late final String localNodeId;
  final String _userName;

  // ── Nearby Connections Config ──────────────────────────────
  // P2P_CLUSTER: true mesh — every device talks to every other device.
  final Strategy _strategy = Strategy.P2P_CLUSTER;
  final String _serviceId = "com.resqmesh.chain_reaction";

  // ── Mesh State ────────────────────────────────────────────
  /// Endpoint ID → MeshNode for all currently connected peers.
  final Map<String, MeshNode> connectedNodes = {};

  int totalRelayCount = 0;
  final List<RelayLogEntry> relayLog = [];

  // ── Dedup Engine ──────────────────────────────────────────
  /// Tracks IDs of alerts we've already processed (deduplication)
  final Set<String> _processedAlertIds = {};
  
  /// Tracks IDs of alerts that have been marked as resolved
  final Set<String> _resolvedAlertIds = {};

  // ── Stream Controller ─────────────────────────────────────
  final StreamController<Alert> _alertStream = StreamController.broadcast();
  Stream<Alert> get alertStream => _alertStream.stream;

  // ── Location Tracking ─────────────────────────────────
  /// All user locations received from the mesh (userId → UserLocation)
  final Map<String, UserLocation> userLocations = {};
  
  /// Stream for live location updates
  final StreamController<UserLocation> _locationStream = StreamController.broadcast();
  Stream<UserLocation> get locationStream => _locationStream.stream;
  
  /// Timer for periodic location broadcast
  Timer? _locationBroadcastTimer;

  // ── Optional callback ─────────────────────────────────────
  final Function(Alert alert)? onAlertReceived;

  // ── Pending connections waiting for acceptConnection ──────
  // We store ConnectionInfo for every initiated connection so we can
  // call acceptConnection for EACH one with the SAME global handler.
  final Map<String, ConnectionInfo> _pendingConnections = {};

  // ── Gateway reference (set after construction via main.dart) ─
  GatewayService? gateway;

  // ── Timers ────────────────────────────────────────────────
  Timer? _discoveryWatchdog;

  // ── Constructor ───────────────────────────────────────────
  MeshService({required String userName, this.onAlertReceived})
      : _userName = userName {
    final rnd = Random().nextInt(9000) + 1000;
    localNodeId = 'node_${DateTime.now().millisecondsSinceEpoch % 100000}_$rnd';
    debugPrint('🆔 ResQMesh: Node ID = $localNodeId');
  }

  // ── Called from GatewayService when a downlink arrives ────
  // Server pushed an alert → inject it into the local BT mesh.
  void injectCloudAlert(Alert alert) {
    debugPrint('☁️ ResQMesh: DOWNLINKING cloud alert [${alert.id}] to local mesh...');
    _handleIncomingPayload(alert.toJson(), sourceEndpointId: 'GLOBAL_CLOUD');
  }

  /// Server pushed a peer's location → inject it into our local mesh
  void injectCloudLocation(UserLocation location) {
    debugPrint('☁️ ResQMesh: DOWNLINKING cloud location [${location.userId}]');
    _handleLocationUpdate(location.toMap(), 'GLOBAL_CLOUD');
  }

  // ============================================================
  // PERMISSIONS + INITIALIZATION
  // ============================================================

  /// Request all permissions needed by Google Nearby Connections.
  /// Returns true only when ALL are granted.
  Future<bool> _requestPermissions() async {
    final List<Permission> perms = [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.nearbyWifiDevices,
    ];

    final statuses = await perms.request();
    bool allOk = true;
    statuses.forEach((p, s) {
      debugPrint('🔐 ResQMesh: $p → $s');
      if (!s.isGranted) allOk = false;
    });
    return allOk;
  }

  /// Start advertising + discovery. Must be called AFTER user taps the
  /// Bluetooth button. Handles permissions and error reporting.
  Future<String?> initializeMesh() async {
    try {
      debugPrint('🔵 ResQMesh [$localNodeId]: Initializing...');

      // ── Step 1: Runtime permissions ───────────────────────
      final ok = await _requestPermissions();
      if (!ok) {
        const msg = 'Permissions denied. Grant Bluetooth + Location and retry.';
        debugPrint('❌ ResQMesh: $msg');
        return msg; // Return error string so UI can show it
      }

      // ── Step 1.5: Check Location Services (GPS) ─────────────
      // Nearby Connections REQUIRES the physical GPS toggle to be ON.
      bool isLocationEnabled = await Geolocator.isLocationServiceEnabled();
      if (!isLocationEnabled) {
        const msg = 'Location services (GPS) are disabled. Please turn on GPS.';
        debugPrint('❌ ResQMesh: $msg');
        return msg;
      }

      // ── Step 2: Start advertising ──────────────────────────
      // The ADVERTISER side fires "ad.onConnectionInitiated" events.
      bool advOk = await Nearby().startAdvertising(
        _userName,
        _strategy,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
        serviceId: _serviceId,
      );
      debugPrint('📣 ResQMesh: Advertising started = $advOk');

      // ── Step 3: Start discovery ────────────────────────────
      // The DISCOVERER side fires "dis.onConnectionInitiated" events.
      // IMPORTANT: requestConnection() inside onEndpointFound sets
      // _discoverConnectionInitiated on the singleton. We pass the
      // SAME handler function reference so it's always correct.
      bool disOk = await Nearby().startDiscovery(
        _userName,
        _strategy,
        onEndpointFound: _onEndpointFound,
        onEndpointLost: (id) {
          debugPrint('🔵 ResQMesh: Endpoint lost: $id');
        },
        serviceId: _serviceId,
      );
      debugPrint('🔍 ResQMesh: Discovery started = $disOk');

      // ── Step 4: Start Discovery Watchdog ────────────────────
      _startDiscoveryWatchdog();

      // ── Step 5: Start Location Broadcasting ──────────────────
      startLocationBroadcast();

      debugPrint('✅ ResQMesh [$localNodeId]: Mesh active.');
      return null; // null = success
    } catch (e) {
      final msg = 'Mesh init failed: $e';
      debugPrint('❌ ResQMesh: $msg');
      return msg;
    }
  }

  // ============================================================
  // LOCATION SHARING — Periodic broadcast to all peers
  // ============================================================

  /// Starts periodic location capture & broadcast (every 5 seconds).
  /// Called automatically at app startup — does NOT require Bluetooth.
  void startLocationBroadcast() {
    if (_locationBroadcastTimer != null) return; // already running
    // Broadcast immediately right now, then every 5 s
    broadcastMyLocationNow();
    _locationBroadcastTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      await broadcastMyLocationNow();
    });
    debugPrint('📍 ResQMesh: Location broadcast started.');
  }

  /// Capture current position and push it to all peers + cloud now.
  /// Called immediately on mesh start and on every 5-second tick.
  Future<void> broadcastMyLocationNow() async {
    try {
      // Get the latest position instantly (kept fresh by LocationService stream)
      final Position? position = await Geolocator.getLastKnownPosition() ?? await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 2),
      );

      if (position == null) return;

      // Create UserLocation object
      final UserLocation myLocation = UserLocation(
        userId: localNodeId,
        userName: _userName,
        latitude: position.latitude,
        longitude: position.longitude,
        timestamp: DateTime.now(),
        accuracy: position.accuracy,
        speed: position.speed,
      );

      // Update local record
      userLocations[localNodeId] = myLocation;

      // Uplink to cloud server if internet is available
      gateway?.uplinkLocation(myLocation);

      // Broadcast to all connected BT peers
      if (connectedNodes.isNotEmpty) {
        await _sendLocationToAllPeers(myLocation);
      }

      notifyListeners();
    } catch (e) {
      debugPrint('⚠️ ResQMesh: Location capture failed: $e');
    }
  }

  /// Sends a location update to all connected peers
  Future<void> _sendLocationToAllPeers(UserLocation location, {String? excludeId}) async {
    if (connectedNodes.isEmpty) return;

    try {
      final Map<String, dynamic> payload = {
        'type': 'location',
        'data': location.toMap(),
      };
      final Uint8List bytes = Uint8List.fromList(
        utf8.encode(json.encode(payload)),
      );

      for (final String peerId in connectedNodes.keys) {
        if (peerId == excludeId) continue; // Don't send back to the source
        try {
          await Nearby().sendBytesPayload(peerId, bytes);
        } catch (e) {
          // Silently skip failed sends
        }
      }
    } catch (e) {
      debugPrint('⚠️ ResQMesh: Location broadcast failed: $e');
    }
  }

  // ============================================================
  // WATCHDOG — Keeps discovery alive
  // ============================================================

  /// Periodically restarts discovery to find new nodes, as some Android
  /// versions stop scanning after a few connections are active.
  void _startDiscoveryWatchdog() {
    _discoveryWatchdog?.cancel();
    _discoveryWatchdog = Timer.periodic(const Duration(seconds: 20), (timer) async {
      // If we have room for more connections in our cluster
      if (connectedNodes.length < 10) {
        debugPrint('🔍 ResQMesh Watchdog: Refreshing discovery...');
        try {
          await Nearby().stopDiscovery();
          await Nearby().startDiscovery(
            _userName,
            _strategy,
            onEndpointFound: _onEndpointFound,
            onEndpointLost: (id) => debugPrint('🔵 ResQMesh: Endpoint lost: $id'),
            serviceId: _serviceId,
          );
        } catch (e) {
          debugPrint('⚠️ ResQMesh Watchdog error: $e');
        }
      }
    });
  }

  // ============================================================
  // CONNECTION MANAGEMENT
  // ============================================================

  /// Called by the DISCOVERER when it spots a new advertiser.
  /// Immediately auto-requests connection.
  void _onEndpointFound(String id, String name, String serviceId) {
    // Avoid double-connecting or connecting to people we already know
    if (connectedNodes.containsKey(id) || _pendingConnections.containsKey(id)) {
      return;
    }

    debugPrint('🔍 ResQMesh: Found peer [$name / $id]. Requesting connection...');

    // NOTE: This call sets _discoverConnectionInitiated on the singleton.
    // We always pass the same _onConnectionInitiated so the handler is stable.
    Nearby().requestConnection(
      _userName,
      id,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
    ).then((result) {
      debugPrint('🔗 ResQMesh: requestConnection to [$id] = $result');
    }).catchError((e) {
      // "Already connected" is not a real error, ignore it
      debugPrint('⚠️ ResQMesh: requestConnection to [$id] error: $e');
    });
  }

  /// Called on BOTH sides when a connection is being established.
  /// We MUST call acceptConnection() here from both sides.
  ///
  /// CRITICAL FIX: We always pass the SAME onPayLoadRecieved lambda
  /// (which captures `this`). Even though the library stores only ONE
  /// global _onPayloadReceived, since we always use the same lambda
  /// pointing to our _handleIncomingPayload, ALL connections share
  /// the same correct handler.
  void _onConnectionInitiated(String id, ConnectionInfo info) async {
    debugPrint('🤝 ResQMesh: Connection initiated — id:[$id] '
        'name:[${info.endpointName}] incoming:${info.isIncomingConnection}');

    // Store pending connection info for reference
    _pendingConnections[id] = info;

    try {
      // BOTH the advertiser and discoverer must call acceptConnection.
      // The onPayLoadRecieved callback registered here becomes the global
      // singleton handler — always pointing to our router.
      final accepted = await Nearby().acceptConnection(
        id,
        onPayLoadRecieved: _handleNearbyPayload,
        onPayloadTransferUpdate: (endpointId, update) {
          // Could show progress bar for large payloads
        },
      );
      debugPrint('✅ ResQMesh: acceptConnection($id) = $accepted');
    } catch (e) {
      debugPrint('❌ ResQMesh: acceptConnection($id) failed: $e');
    }
  }

  /// The ONE global payload handler — always the same function reference.
  /// Since the library stores only one _onPayloadReceived, this MUST be
  /// a stable method reference (not an inline lambda that changes).
  void _handleNearbyPayload(String endpointId, Payload payload) {
    if (payload.type == PayloadType.BYTES && payload.bytes != null) {
      try {
        final String jsonStr = utf8.decode(payload.bytes!);
        debugPrint('📦 ResQMesh: Raw bytes from [$endpointId]: '
            '${jsonStr.substring(0, jsonStr.length.clamp(0, 80))}...');
        _handleIncomingPayload(jsonStr, sourceEndpointId: endpointId);
      } catch (e) {
        debugPrint('❌ ResQMesh: Payload decode error: $e');
      }
    }
  }

  /// Called when the connection handshake completes (success or fail).
  void _onConnectionResult(String id, Status status) {
    _pendingConnections.remove(id);

    if (status == Status.CONNECTED) {
      debugPrint('🟢 ResQMesh: CONNECTED to [$id]');
      connectedNodes[id] = MeshNode(
        id: id,
        name: 'Node_$id',
        lastSeen: DateTime.now(),
      );
      notifyListeners();
    } else {
      debugPrint('🔴 ResQMesh: Connection FAILED for [$id] — status: $status');
      connectedNodes.remove(id);
      notifyListeners();
    }
  }

  /// Called when a connected peer goes out of range.
  void _onDisconnected(String id) {
    debugPrint('🔌 ResQMesh: [$id] disconnected.');
    connectedNodes.remove(id);
    _pendingConnections.remove(id);
    notifyListeners();
  }

  // ============================================================
  // CHAIN REACTION — ORIGINATE & RESOLVE
  // ============================================================

  /// Called when THIS device creates a new alert.
  /// Adds to dedup, then sends to all connected BT neighbors.
  Future<void> broadcastAlert(Alert alert) async {
    if (_processedAlertIds.contains(alert.id)) {
      debugPrint('⚠️ ResQMesh: Alert [${alert.id}] already processed. Skip.');
      return;
    }
    _processedAlertIds.add(alert.id);
    if (alert.isResolved) _resolvedAlertIds.add(alert.id);

    debugPrint('📢 ResQMesh [$localNodeId]: Broadcasting alert [${alert.id}] '
        'to ${connectedNodes.length} peer(s)...');

    // If we have internet, gateway will uplink to the server
    gateway?.uplinkAlert(alert);

    if (connectedNodes.isEmpty) {
      debugPrint('⚠️ ResQMesh: No peers connected! Alert stays local only.');
    }

    await _sendToAllPeers(alert, excludeNodeId: null);
  }

  /// Resolves an existing alert that was broadcasted by this device
  Future<void> resolveAlert(Alert alert) async {
    if (alert.originNodeId != localNodeId) return; // Only creator can resolve
    
    final resolvedAlert = Alert(
      id: alert.id,
      originNodeId: alert.originNodeId,
      senderId: localNodeId,
      alertType: alert.alertType,
      description: alert.description,
      latitude: alert.latitude,
      longitude: alert.longitude,
      timestamp: alert.timestamp,
      severity: alert.severity,
      action: 'Emergency Resolved',
      hopCount: 0,
      ttl: 15, // Reset TTL so the resolution propagates through the whole mesh
      isResolved: true,
    );

    // Remove from active dedup so we process it, but add to resolved dedup
    _processedAlertIds.remove(alert.id);
    await broadcastAlert(resolvedAlert);
  }

  // ============================================================
  // CHAIN REACTION — RECEIVE & RELAY
  // ============================================================

  /// Core handler. Invoked every time bytes arrive from a BT peer.
  void _handleIncomingPayload(String jsonStr,
      {required String sourceEndpointId}) {
    try {
      // Try to parse as generic payload first
      final dynamic decoded = json.decode(jsonStr);
      
      // Check if it's a location update
      if (decoded is Map && decoded['type'] == 'location') {
        _handleLocationUpdate(decoded['data'], sourceEndpointId);
        return;
      }

      final Alert incoming = Alert.fromJson(jsonStr);

      // Guard 1: Dedup
      if (_processedAlertIds.contains(incoming.id)) {
        // If it's a new resolution for an alert we already have, allow it through ONCE
        if (incoming.isResolved && !_resolvedAlertIds.contains(incoming.id)) {
          debugPrint('✅ ResQMesh: Received RESOLUTION for [${incoming.id}]');
          _resolvedAlertIds.add(incoming.id);
        } else {
          debugPrint('🔁 ResQMesh: Duplicate [${incoming.id}] from [$sourceEndpointId]. Drop.');
          return;
        }
      } else {
        if (incoming.isResolved) _resolvedAlertIds.add(incoming.id);
        _processedAlertIds.add(incoming.id);
      }

      // Guard 2: TTL
      if (incoming.isExpired) {
        debugPrint(
            '⏰ ResQMesh: TTL=0 for [${incoming.id}]. Chain terminated.');
        return;
      }

      debugPrint('📬 ResQMesh [$localNodeId]: NEW alert/update [${incoming.id}] '
          'hop=${incoming.hopCount} ttl=${incoming.ttl} resolved=${incoming.isResolved}');

      // If this phone has internet, uplink the alert to the global server
      gateway?.uplinkAlert(incoming);

      // Notify UI
      _alertStream.add(incoming);
      onAlertReceived?.call(incoming);

      // Trigger mobile push notification (only if it's a new emergency, not a resolution)
      if (incoming.originNodeId != localNodeId && !incoming.isResolved) {
        NotificationService().showEmergencyAlert(incoming);
      }

      // Build relayed version (increments hop, decrements TTL)
      final Alert relayed = incoming.relayedBy(localNodeId);

      // Log relay event
      _logRelayEvent(
        alertId: incoming.id,
        fromNodeId: sourceEndpointId,
        toNodeId: localNodeId,
        hopNumber: relayed.hopCount,
      );

      // Forward to all OTHER peers
      _sendToAllPeers(relayed, excludeNodeId: sourceEndpointId);
    } catch (e) {
      debugPrint('❌ ResQMesh: Failed to parse incoming payload: $e\n'
          'Raw: ${jsonStr.substring(0, jsonStr.length.clamp(0, 200))}');
    }
  }
  /// Handles incoming location update from a peer
  void _handleLocationUpdate(Map<String, dynamic> locationData, String sourceId) {
    try {
      final UserLocation location = UserLocation.fromMap(locationData);
      
      // Dedup/Anti-loop: only process/relay if this location is newer than what we have
      final existing = userLocations[location.userId];
      if (existing != null && !location.timestamp.isAfter(existing.timestamp)) {
        return;
      }

      // Update our location map
      userLocations[location.userId] = location;
      
      // Notify listeners via stream
      _locationStream.add(location);
      
      debugPrint('📍 ResQMesh: Location update from [${location.userName}] (source=$sourceId)');
      
      // RELAY: Forward this location update to all other connected peers
      // (This creates the multi-hop mesh effect for locations)
      if (connectedNodes.isNotEmpty) {
        _sendLocationToAllPeers(location, excludeId: sourceId);
      }

      // If we have internet, uplink this peer's location to the cloud as well
      // (Ensures the cloud knows about nodes that only have Bluetooth mesh)
      if (sourceId != 'GLOBAL_CLOUD') {
        gateway?.uplinkLocation(location);
      }

      notifyListeners();
    } catch (e) {
      debugPrint('⚠️ ResQMesh: Failed to parse/relay location: $e');
    }
  }

  // ============================================================
  // TRANSPORT LAYER
  // ============================================================

  Future<void> _sendToAllPeers(Alert alert,
      {required String? excludeNodeId}) async {
    if (connectedNodes.isEmpty) {
      debugPrint('⚠️ ResQMesh: No peers to send to.');
      return;
    }

    final Uint8List bytes =
        Uint8List.fromList(utf8.encode(alert.toJson()));

    final targets = connectedNodes.keys
        .where((id) => id != excludeNodeId)
        .toList();

    debugPrint(
        '📡 ResQMesh: Sending [${alert.id}] to ${targets.length} peer(s)...');

    for (final String nodeId in targets) {
      try {
        await Nearby().sendBytesPayload(nodeId, bytes);
        totalRelayCount++;
        debugPrint(
            '  ✓ Sent → [$nodeId] (hop=${alert.hopCount}, ttl=${alert.ttl})');
        notifyListeners();
      } catch (e) {
        debugPrint('  ✗ Failed → [$nodeId]: $e');
        // Remove dead connections
        if (e.toString().contains('endpoint') ||
            e.toString().contains('disconnected')) {
          connectedNodes.remove(nodeId);
          notifyListeners();
        }
      }
    }
  }

  // ============================================================
  // RELAY LOG
  // ============================================================

  void _logRelayEvent({
    required String alertId,
    required String fromNodeId,
    required String toNodeId,
    required int hopNumber,
  }) {
    relayLog.add(RelayLogEntry(
      alertId: alertId,
      fromNodeId: fromNodeId,
      toNodeId: toNodeId,
      hopNumber: hopNumber,
      relayedAt: DateTime.now(),
    ));
    notifyListeners();
  }

  // ============================================================
  // DIAGNOSTICS — Call from UI to check state
  // ============================================================

  String get diagnosticSummary {
    return 'Node: $localNodeId\n'
        'Connected peers: ${connectedNodes.length}\n'
        'Processed alerts: ${_processedAlertIds.length}\n'
        'Total relays: $totalRelayCount\n'
        'Peer IDs: ${connectedNodes.keys.join(', ')}';
  }

  // ============================================================
  // CLEANUP
  // ============================================================

  Future<void> disposeMesh() async {
    try {
      _discoveryWatchdog?.cancel();
      _locationBroadcastTimer?.cancel();
      await Nearby().stopAdvertising();
      await Nearby().stopDiscovery();
      await Nearby().stopAllEndpoints();
    } catch (e) {
      debugPrint('⚠️ ResQMesh: Error during dispose: $e');
    }
    if (!_alertStream.isClosed) await _alertStream.close();
    if (!_locationStream.isClosed) await _locationStream.close();
    connectedNodes.clear();
    _pendingConnections.clear();
    userLocations.clear();
    debugPrint('🔴 ResQMesh [$localNodeId]: Mesh shut down.');
  }

  @override
  void dispose() {
    disposeMesh();
    super.dispose();
  }
}
