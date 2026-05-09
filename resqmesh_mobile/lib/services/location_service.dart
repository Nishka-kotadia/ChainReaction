import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

// ============================================================
// ResQMesh — Location Service
// Handles permission requests, GPS state checks, and live
// position streaming for the location feature.
// ============================================================

class LocationService extends ChangeNotifier {
  Position? _currentPosition;
  bool _hasPermission = false;
  bool _isTracking = false;
  String? _errorMessage;

  StreamSubscription<Position>? _positionSubscription;

  Position? get currentPosition => _currentPosition;
  bool get hasPermission => _hasPermission;
  bool get isTracking => _isTracking;
  String? get errorMessage => _errorMessage;

  // ── Permission & Initialization ───────────────────────────

  /// Request location permission and check GPS state.
  /// Returns null on success, or an error string.
  Future<String?> requestPermission() async {
    // Check if location services are enabled
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _errorMessage = 'GPS is disabled. Please turn on location services.';
      notifyListeners();
      return _errorMessage;
    }

    // Request fine location permission
    final status = await Permission.locationWhenInUse.request();
    if (!status.isGranted) {
      _errorMessage = 'Location permission denied.';
      _hasPermission = false;
      notifyListeners();
      return _errorMessage;
    }

    _hasPermission = true;
    _errorMessage = null;
    notifyListeners();
    return null;
  }

  /// Get the current position once (used for SOS broadcast).
  Future<Position?> getCurrentPosition() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      _currentPosition = pos;
      notifyListeners();
      return pos;
    } catch (e) {
      debugPrint('⚠️ LocationService: getCurrentPosition failed: $e');
      return null;
    }
  }

  /// Start continuous position tracking.
  void startTracking() {
    if (_isTracking) return;

    const settings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10, // Update every 10 metres of movement
    );

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(
      (Position pos) {
        _currentPosition = pos;
        notifyListeners();
      },
      onError: (e) {
        debugPrint('⚠️ LocationService: Stream error: $e');
      },
    );

    _isTracking = true;
    notifyListeners();
  }

  /// Stop continuous position tracking.
  void stopTracking() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _isTracking = false;
    notifyListeners();
  }

  @override
  void dispose() {
    stopTracking();
    super.dispose();
  }
}
