import 'dart:convert';

// ============================================================
// ResQMesh — Core Data Models
// Supports chain-reaction relay: TTL, hopCount, originNodeId
// ============================================================

/// Represents a node (device) in the Bluetooth mesh network.
class MeshNode {
  final String id;
  final String name;
  final DateTime lastSeen;
  final int rssi; // Signal strength (higher = closer)

  MeshNode({
    required this.id,
    required this.name,
    required this.lastSeen,
    this.rssi = 0,
  });

  /// Returns a human-readable proximity label from RSSI value.
  String get proximityLabel {
    if (rssi >= -50) return 'Very Close';
    if (rssi >= -70) return 'Close';
    if (rssi >= -85) return 'Mid-Range';
    return 'Far';
  }
}

/// Severity of an emergency alert — drives triage priority.
enum SeverityScore { low, medium, high, critical }

/// The type/category of emergency — used for icon and filter display.
enum AlertType { fire, flood, injury, trapped, missing, earthquake, general }

/// ---------------------------------------------------------------
/// Alert — the core chain-reaction payload.
///
/// Every time this alert is relayed by an intermediate node:
///   - [hopCount] increments by 1
///   - [ttl] decrements by 1 (chain stops at 0)
///   - [relayPath] appends the relay node's ID (audit trail)
/// ---------------------------------------------------------------
class Alert {
  final String id;             // Unique UUID — used for dedup
  final String originNodeId;   // The device that FIRST created this alert
  final String senderId;       // The device that sent THIS particular hop
  final AlertType alertType;
  final String description;
  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final SeverityScore severity;
  final String action;
  final int hopCount;          // How many relays this alert has passed through
  final int ttl;               // Time-To-Live: chain stops when this hits 0
  final List<String> relayPath; // Ordered list of node IDs that relayed this
  final bool isResolved;       // True if the emergency has been resolved

  Alert({
    required this.id,
    required this.originNodeId,
    required this.senderId,
    required this.alertType,
    required this.description,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.severity,
    required this.action,
    this.hopCount = 0,
    this.ttl = 15,              // Default: allow up to 15 hops
    this.relayPath = const [],
    this.isResolved = false,
  });

  /// Creates a new Alert instance with hop metadata incremented.
  /// Called by every intermediate relay node before re-broadcasting.
  Alert relayedBy(String relayNodeId) {
    return Alert(
      id: id,
      originNodeId: originNodeId,
      senderId: relayNodeId,   // The node doing the relay becomes the new sender
      alertType: alertType,
      description: description,
      latitude: latitude,
      longitude: longitude,
      timestamp: timestamp,
      severity: severity,
      action: action,
      hopCount: hopCount + 1,
      ttl: ttl - 1,            // Consume one TTL unit
      relayPath: [...relayPath, relayNodeId], // Append relay audit trail
      isResolved: isResolved,
    );
  }

  /// True when this alert has exhausted its allowed relay depth.
  bool get isExpired => ttl <= 0;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'originNodeId': originNodeId,
      'senderId': senderId,
      'alertType': alertType.toString().split('.').last,
      'description': description,
      'latitude': latitude,
      'longitude': longitude,
      'timestamp': timestamp.toIso8601String(),
      'severity': severity.toString().split('.').last,
      'action': action,
      'hopCount': hopCount,
      'ttl': ttl,
      'relayPath': relayPath,
      'isResolved': isResolved,
    };
  }

  factory Alert.fromMap(Map<String, dynamic> map) {
    return Alert(
      id: map['id'],
      originNodeId: map['originNodeId'] ?? map['senderId'],
      senderId: map['senderId'],
      alertType: AlertType.values.firstWhere(
        (e) => e.toString().split('.').last == map['alertType'],
        orElse: () => AlertType.general,
      ),
      description: map['description'],
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      timestamp: DateTime.parse(map['timestamp']),
      severity: SeverityScore.values.firstWhere(
        (e) => e.toString().split('.').last == map['severity'],
        orElse: () => SeverityScore.low,
      ),
      action: map['action'],
      hopCount: map['hopCount'] ?? 0,
      ttl: map['ttl'] ?? 15,
      relayPath: List<String>.from(map['relayPath'] ?? []),
      isResolved: map['isResolved'] ?? false,
    );
  }

  /// Serializes to compact JSON bytes for Bluetooth transmission.
  String toJson() => json.encode(toMap());
  factory Alert.fromJson(String source) => Alert.fromMap(json.decode(source));
}

/// A log entry recording one relay event in the chain reaction.
class RelayLogEntry {
  final String alertId;
  final String fromNodeId;
  final String toNodeId;
  final int hopNumber;
  final DateTime relayedAt;

  RelayLogEntry({
    required this.alertId,
    required this.fromNodeId,
    required this.toNodeId,
    required this.hopNumber,
    required this.relayedAt,
  });
}

/// ---------------------------------------------------------------
/// UserLocation — represents a user's live GPS position in the mesh.
///
/// Broadcast periodically by each device to all connected peers.
/// ---------------------------------------------------------------
class UserLocation {
  final String userId;        // The device node ID
  final String userName;      // Human-readable device name
  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final double? accuracy;     // GPS accuracy in meters (optional)
  final double? speed;        // Speed in m/s (optional)

  UserLocation({
    required this.userId,
    required this.userName,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracy,
    this.speed,
  });

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'userName': userName,
      'latitude': latitude,
      'longitude': longitude,
      'timestamp': timestamp.toIso8601String(),
      'accuracy': accuracy,
      'speed': speed,
    };
  }

  factory UserLocation.fromMap(Map<String, dynamic> map) {
    return UserLocation(
      userId: map['userId'],
      userName: map['userName'],
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      timestamp: DateTime.parse(map['timestamp']),
      accuracy: map['accuracy'] != null ? (map['accuracy'] as num).toDouble() : null,
      speed: map['speed'] != null ? (map['speed'] as num).toDouble() : null,
    );
  }

  String toJson() => json.encode(toMap());
  factory UserLocation.fromJson(String source) => UserLocation.fromMap(json.decode(source));
}
