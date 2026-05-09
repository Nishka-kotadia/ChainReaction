import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';
import 'mesh_service.dart';

// ================================================================
// ResQMesh — Internet Gateway Service
//
// Works on ANY internet connection — mobile data, any Wi-Fi, etc.
// The server URL is stored in SharedPreferences so it can be changed
// at runtime from a settings screen without rebuilding the APK.
//
// DEFAULT: Public tunnel URL (works on any network globally)
// ================================================================

class GatewayService extends ChangeNotifier {
  // ── Default server URL ────────────────────────────────────────
  // This is the localtunnel public URL. Replace with your Render/
  // Railway deployed URL for a permanent production server.
  static const String _defaultServerUrl = 'https://server-chain-reaction.onrender.com';
  static const String _prefKey = 'resqmesh_server_url';

  // Expose the default so the settings UI can reference it
  static const String defaultServerUrl = _defaultServerUrl;

  // ── Identity ──────────────────────────────────────────────────
  final String nodeId;

  // ── State ─────────────────────────────────────────────────────
  String _serverUrl = _defaultServerUrl;
  bool _isConnected = false;
  bool _hasInternet = false;
  int _globalConnectedCount = 0;
  final List<Alert> _serverAlerts = [];

  String get serverUrl => _serverUrl;
  bool get isConnected => _isConnected;
  bool get hasInternet => _hasInternet;
  int get globalConnectedCount => _globalConnectedCount;
  List<Alert> get serverAlerts => List.unmodifiable(_serverAlerts);

  // ── Callback: fires when server pushes an alert/location DOWN ──
  final void Function(Alert alert)? onServerAlert;
  final void Function(UserLocation location)? onServerLocation;

  // ── Back-reference to MeshService (for immediate location uplink on connect)
  MeshService? mesh;

  // ── Internals ─────────────────────────────────────────────────
  IO.Socket? _socket;
  StreamSubscription? _connectivitySub;

  // Dedup: prevents re-processing alerts that came FROM the server
  final Set<String> _processedIds = {};

  GatewayService({required this.nodeId, this.onServerAlert, this.onServerLocation}) {
    _loadAndInit();
  }

  // ================================================================
  // INIT — Load saved URL then start
  // ================================================================

  Future<void> _loadAndInit() async {
    final prefs = await SharedPreferences.getInstance();
    _serverUrl = prefs.getString(_prefKey) ?? _defaultServerUrl;
    debugPrint('🌐 Gateway: Using server URL → $_serverUrl');
    _initConnectivity();
  }

  /// Change the server URL at runtime (from settings screen).
  /// Reconnects immediately to the new server.
  Future<void> updateServerUrl(String newUrl) async {
    final url = newUrl.trim().replaceAll(RegExp(r'/$'), ''); // strip trailing slash
    _serverUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, url);
    debugPrint('⚙️ Gateway: Server URL updated → $url');

    // Reconnect to new server
    _socket?.dispose();
    _isConnected = false;
    notifyListeners();
    if (_hasInternet) _connectSocket();
  }

  /// Reset to the default tunnel URL.
  Future<void> resetServerUrl() => updateServerUrl(_defaultServerUrl);

  // ================================================================
  // CONNECTIVITY MONITORING
  // ================================================================

  void _initConnectivity() {
    Connectivity().checkConnectivity().then(_handleConnectivityChange);
    _connectivitySub = Connectivity().onConnectivityChanged.listen(
      _handleConnectivityChange,
    );
  }

  void _handleConnectivityChange(List<ConnectivityResult> results) {
    final hadInternet = _hasInternet;
    _hasInternet = results.any((r) => r != ConnectivityResult.none);

    if (_hasInternet && !hadInternet) {
      debugPrint('🌐 Gateway: Internet detected (${results.first.name}). Connecting...');
      _connectSocket();
    } else if (!_hasInternet && hadInternet) {
      debugPrint('📵 Gateway: Internet lost.');
      _socket?.disconnect();
      _isConnected = false;
      notifyListeners();
    }
  }

  // ================================================================
  // WEBSOCKET CONNECTION
  // ================================================================

  void _connectSocket() {
    _socket?.dispose();

    debugPrint('🔌 Gateway: Connecting to $_serverUrl ...');

    _socket = IO.io(
      _serverUrl,
      IO.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .setQuery({'nodeId': nodeId})
          .enableAutoConnect()
          .enableReconnection()
          .setReconnectionAttempts(99999)
          .setReconnectionDelay(3000)
          .setExtraHeaders({
            // localtunnel requires this header to bypass the landing page
            'bypass-tunnel-reminder': 'true',
          })
          .build(),
    );

    _socket!.onConnect((_) {
      debugPrint('✅ Gateway: CONNECTED to server [$_serverUrl]');
      _isConnected = true;
      notifyListeners();
      // Immediately push our location so server & other clients see us now
      mesh?.broadcastMyLocationNow();
      // Also fetch all existing locations via HTTP as a guaranteed fallback
      // (in case the WS location_snapshot event was missed)
      _fetchAllLocations();
    });

    _socket!.onDisconnect((_) {
      debugPrint('🔴 Gateway: Disconnected from server');
      _isConnected = false;
      notifyListeners();
    });

    _socket!.onConnectError((err) {
      debugPrint('⚠️ Gateway: Connect error → $err');
      _isConnected = false;
      notifyListeners();
    });

    _socket!.on('new_alert', (data) {
      debugPrint('📡 Gateway: Alert received from server');
      _handleServerAlert(data);
    });

    _socket!.on('location_update', (data) {
      _handleServerLocation(data);
    });

    // Snapshot of all existing users, sent by server on connect
    _socket!.on('location_snapshot', (data) {
      debugPrint('📍 Gateway: Received location snapshot (${(data as List).length} users)');
      for (final item in data) {
        _handleServerLocation(item);
      }
    });

    _socket!.on('alert_history', (data) {
      debugPrint('📜 Gateway: Received history (${(data as List).length} alerts)');
      for (final item in data) {
        _handleServerAlert(item);
      }
    });

    _socket!.on('node_joined', (data) {
      _globalConnectedCount = (data['totalConnected'] as int?) ?? _globalConnectedCount;
      notifyListeners();
    });

    _socket!.on('node_left', (data) {
      _globalConnectedCount = (data['totalConnected'] as int?) ?? _globalConnectedCount;
      notifyListeners();
    });

    _socket!.connect();
  }

  void _handleServerAlert(dynamic data) {
    try {
      final Map<String, dynamic> map =
          data is String ? json.decode(data) : Map<String, dynamic>.from(data);
      final Alert alert = Alert.fromMap(map);

      if (_processedIds.contains(alert.id)) return;
      _processedIds.add(alert.id);

      _serverAlerts.add(alert);
      if (_serverAlerts.length > 100) _serverAlerts.removeAt(0);

      onServerAlert?.call(alert);
      notifyListeners();
    } catch (e) {
      debugPrint('❌ Gateway: Failed to parse server alert: $e');
    }
  }

  void _handleServerLocation(dynamic data) {
    try {
      final Map<String, dynamic> map =
          data is String ? json.decode(data) : Map<String, dynamic>.from(data);
      final UserLocation location = UserLocation.fromMap(map);

      // Don't process our own location coming back
      if (location.userId == nodeId) return;

      onServerLocation?.call(location);
    } catch (e) {
      debugPrint('❌ Gateway: Failed to parse server location: $e');
    }
  }

  // ================================================================
  // UPLINK — Phone → Server
  // ================================================================

  Future<void> uplinkAlert(Alert alert) async {
    if (!_hasInternet) return;
    if (_processedIds.contains(alert.id)) return; // don't echo back

    debugPrint('☁️ Gateway: Uplinking [${alert.id.substring(0, 8)}...] to server');

    // Strategy 1: WebSocket (fastest)
    if (_isConnected && _socket != null) {
      _socket!.emit('send_alert', alert.toMap());
      return;
    }

    // Strategy 2: HTTP POST fallback
    try {
      final response = await http.post(
        Uri.parse('$_serverUrl/api/alert'),
        headers: {
          'Content-Type': 'application/json',
          'bypass-tunnel-reminder': 'true', // Required for localtunnel
        },
        body: json.encode(alert.toMap()),
      ).timeout(const Duration(seconds: 10));

      debugPrint('✅ Gateway: HTTP uplink → ${response.statusCode}');
    } catch (e) {
      debugPrint('❌ Gateway: HTTP uplink failed: $e');
    }
  }

  Future<void> uplinkLocation(UserLocation location) async {
    if (!_hasInternet || !_isConnected || _socket == null) return;
    _socket!.emit('location_update', location.toMap());
  }

  /// HTTP fallback: fetch all known peer locations from the server.
  /// Called on socket connect to guarantee we see everyone immediately.
  Future<void> _fetchAllLocations() async {
    if (!_hasInternet) return;
    try {
      final response = await http.get(
        Uri.parse('$_serverUrl/api/locations'),
        headers: {'bypass-tunnel-reminder': 'true'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List<dynamic> locations = data['locations'] ?? [];
        debugPrint('📍 Gateway: HTTP fetched ${locations.length} peer location(s)');
        for (final item in locations) {
          _handleServerLocation(item);
        }
      }
    } catch (e) {
      debugPrint('⚠️ Gateway: _fetchAllLocations failed: $e');
    }
  }

  // ================================================================
  // SERVER STATUS
  // ================================================================

  Future<Map<String, dynamic>?> fetchServerStatus() async {
    if (!_hasInternet) return null;
    try {
      final response = await http.get(
        Uri.parse('$_serverUrl/api/status'),
        headers: {'bypass-tunnel-reminder': 'true'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _globalConnectedCount = data['connectedClients'] ?? 0;
        notifyListeners();
        return data;
      }
    } catch (e) {
      debugPrint('❌ Gateway: Status fetch failed: $e');
    }
    return null;
  }

  // ================================================================
  // CLEANUP
  // ================================================================

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _socket?.dispose();
    super.dispose();
  }
}
