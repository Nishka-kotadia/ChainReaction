import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../services/location_service.dart';
import '../services/cached_tile_provider.dart';

import '../services/mesh_service.dart';
import '../services/gateway_service.dart';
import '../services/models.dart';
import '../services/ai_triage.dart';
import '../services/disaster_verifier.dart';
import 'server_settings_screen.dart';

// =============================================================
// ResQMesh — Main UI
// Wired fully to MeshService chain-reaction engine.
// =============================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  // All alerts received (from mesh OR originated locally)
  final List<Alert> _alerts = [];

  // Stream subscription to the MeshService alert stream
  StreamSubscription<Alert>? _alertSubscription;

  bool _isMeshActive = false;

  @override
  void initState() {
    super.initState();
    _seedDemoAlerts();     // Pre-load 2 demo alerts so the UI isn't empty
    _listenToMesh();       // Subscribe to incoming chain-reaction alerts
  }

  /// Subscribe to alerts arriving from the mesh network in real-time.
  void _listenToMesh() {
    final mesh = context.read<MeshService>();
    _alertSubscription = mesh.alertStream.listen((alert) {
      if (mounted) {
        setState(() {
          if (alert.isResolved) {
            _alerts.removeWhere((a) => a.id == alert.id);
          } else {
            // Check if it already exists before inserting
            final exists = _alerts.any((a) => a.id == alert.id);
            if (!exists) {
              _alerts.insert(0, alert);
            }
          }
        });
      }
    });
  }

  /// Two realistic demo alerts so the dashboard isn't blank at launch.
  void _seedDemoAlerts() {
    // Removed hardcoded demo alerts as requested
  }

  @override
  void dispose() {
    _alertSubscription?.cancel();
    super.dispose();
  }

  Future<void> _toggleMesh() async {
    final mesh = context.read<MeshService>();
    if (_isMeshActive) {
      await mesh.disposeMesh();
      if (mounted) setState(() => _isMeshActive = false);
    } else {
      final error = await mesh.initializeMesh();
      if (error != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error),
              backgroundColor: const Color(0xFFF43F5E),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } else {
        if (mounted) setState(() => _isMeshActive = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 10, height: 10,
              decoration: BoxDecoration(
                color: _isMeshActive ? Colors.greenAccent : Colors.redAccent,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: (_isMeshActive ? Colors.greenAccent : Colors.redAccent).withOpacity(0.6),
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            const Text('ResQMesh', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.5, fontSize: 18)),
          ],
        ),
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Server Settings',
            icon: const Icon(Icons.settings),
            color: Colors.white70,
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ServerSettingsScreen()),
              );
            },
          ),
          IconButton(
            tooltip: _isMeshActive ? 'Deactivate Mesh' : 'Activate Mesh',
            icon: Icon(_isMeshActive ? Icons.bluetooth_connected : Icons.bluetooth_disabled),
            color: _isMeshActive ? Colors.greenAccent : Colors.grey,
            onPressed: _toggleMesh,
          ),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _DashboardTab(alerts: _alerts, isMeshActive: _isMeshActive),
          _TriageTab(onAlertCreated: _onAlertCreated),
          _LocationsMapTab(alerts: _alerts),
          const _RelayLogTab(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
        backgroundColor: const Color(0xFF1E293B),
        selectedItemColor: const Color(0xFF38BDF8),
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard_rounded), label: 'Dashboard'),
          BottomNavigationBarItem(icon: Icon(Icons.emergency), label: 'SOS'),
          BottomNavigationBarItem(icon: Icon(Icons.location_on), label: 'Map'),
          BottomNavigationBarItem(icon: Icon(Icons.account_tree_rounded), label: 'Chain Log'),
        ],
      ),
    );
  }

  /// Called when the user broadcasts a new alert from the SOS tab.
  void _onAlertCreated(Alert alert) {
    setState(() => _alerts.insert(0, alert));
    // Fire into the Bluetooth mesh — chain reaction begins here
    context.read<MeshService>().broadcastAlert(alert);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('🔴 Alert broadcasted! Chain reaction started.'),
        backgroundColor: const Color(0xFFF43F5E),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

// =============================================================
// TAB 1 — Dashboard: Live alert feed
// =============================================================
class _DashboardTab extends StatelessWidget {
  final List<Alert> alerts;
  final bool isMeshActive;

  const _DashboardTab({required this.alerts, required this.isMeshActive});

  @override
  Widget build(BuildContext context) {
    return Consumer<MeshService>(
      builder: (context, mesh, _) {
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _buildMeshStatusCard(mesh)),
            SliverToBoxAdapter(child: _buildSectionHeader('Active Emergencies', alerts.length)),
            if (alerts.isEmpty)
              SliverToBoxAdapter(child: _buildEmptyState()),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => _AlertCard(alert: alerts[i], mesh: mesh),
                childCount: alerts.length,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }

  Widget _buildMeshStatusCard(MeshService mesh) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isMeshActive
              ? [const Color(0xFF064E3B), const Color(0xFF1E293B)]
              : [const Color(0xFF1E293B), const Color(0xFF0F172A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isMeshActive ? Colors.greenAccent.withOpacity(0.3) : Colors.white12,
        ),
      ),
      child: Row(
        children: [
          // Pulsing Bluetooth icon
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: (isMeshActive ? Colors.greenAccent : Colors.grey).withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isMeshActive ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
              color: isMeshActive ? Colors.greenAccent : Colors.grey,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isMeshActive ? 'MESH ACTIVE' : 'MESH OFFLINE',
                  style: TextStyle(
                    color: isMeshActive ? Colors.greenAccent : Colors.grey,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isMeshActive
                      ? '${mesh.connectedNodes.length} BT nodes connected'
                      : 'Tap Bluetooth icon to activate',
                  style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                ),
                if (isMeshActive) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${mesh.totalRelayCount} chain relays executed',
                    style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  Consumer<GatewayService>(
                    builder: (_, gw, __) => Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: gw.isConnected
                                ? Colors.blueAccent
                                : gw.hasInternet
                                    ? Colors.orangeAccent
                                    : Colors.grey,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          gw.isConnected
                              ? 'SERVER: ${gw.globalConnectedCount} global devices'
                              : gw.hasInternet
                                  ? 'CONNECTING TO SERVER...'
                                  : 'LOCAL MESH ONLY (no internet)',
                          style: TextStyle(
                            color: gw.isConnected
                                ? Colors.blueAccent
                                : gw.hasInternet
                                    ? Colors.orangeAccent
                                    : Colors.grey,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text('$count', style: const TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Padding(
      padding: EdgeInsets.all(48),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.check_circle_outline, color: Colors.greenAccent, size: 48),
            SizedBox(height: 16),
            Text('No active emergencies', style: TextStyle(color: Colors.grey, fontSize: 16)),
          ],
        ),
      ),
    );
  }
}

// =============================================================
// Alert Card Widget
// =============================================================
class _AlertCard extends StatelessWidget {
  final Alert alert;
  final MeshService mesh;
  const _AlertCard({required this.alert, required this.mesh});

  @override
  Widget build(BuildContext context) {
    final Color severityColor = _severityColor(alert.severity);
    final String timeAgo = _formatTimestamp(alert.timestamp);
    final String senderName = alert.originNodeId == mesh.localNodeId 
        ? 'You' 
        : (mesh.userLocations[alert.originNodeId]?.userName ?? 'Unknown User');

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: severityColor.withOpacity(0.35), width: 1.5),
        boxShadow: [BoxShadow(color: severityColor.withOpacity(0.08), blurRadius: 10)],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                _SeverityBadge(severity: alert.severity),
                const SizedBox(width: 8),
                _TypeBadge(alertType: alert.alertType),
                const Spacer(),
                Text(timeAgo, style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 11)),
              ],
            ),
            const SizedBox(height: 10),
            
            // Sender Info
            Row(
              children: [
                Icon(Icons.person, color: Colors.white54, size: 14),
                const SizedBox(width: 4),
                Text('Broadcasted by: $senderName', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 12),

            // Description
            Text(alert.description,
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500, height: 1.4)),
            const SizedBox(height: 12),

            // Action box
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined, color: severityColor, size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Text(alert.action,
                      style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 12))),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Chain metadata row
            Row(
              children: [
                _MetaChip(icon: Icons.alt_route, label: '${alert.hopCount} hops'),
                const SizedBox(width: 8),
                _MetaChip(icon: Icons.timer, label: 'TTL: ${alert.ttl}'),
                const Spacer(),
                if (alert.originNodeId == mesh.localNodeId && !alert.isResolved)
                  TextButton.icon(
                    onPressed: () {
                      mesh.resolveAlert(alert);
                      // Instantly remove from local UI
                      final homeState = context.findAncestorStateOfType<_HomeScreenState>();
                      if (homeState != null) {
                        homeState.setState(() {
                          homeState._alerts.removeWhere((a) => a.id == alert.id);
                        });
                      }
                    },
                    icon: const Icon(Icons.check_circle, color: Colors.greenAccent, size: 16),
                    label: const Text('END EMERGENCY', style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      backgroundColor: Colors.greenAccent.withOpacity(0.1),
                      minimumSize: Size.zero,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _severityColor(SeverityScore s) {
    switch (s) {
      case SeverityScore.critical: return const Color(0xFFF43F5E);
      case SeverityScore.high:     return const Color(0xFFF97316);
      case SeverityScore.medium:   return const Color(0xFFFACC15);
      case SeverityScore.low:      return const Color(0xFF38BDF8);
    }
  }

  String _formatTimestamp(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }
}

class _SeverityBadge extends StatelessWidget {
  final SeverityScore severity;
  const _SeverityBadge({required this.severity});

  @override
  Widget build(BuildContext context) {
    final Map<SeverityScore, List<dynamic>> map = {
      SeverityScore.critical: [const Color(0xFFF43F5E), 'CRITICAL'],
      SeverityScore.high:     [const Color(0xFFF97316), 'HIGH'],
      SeverityScore.medium:   [const Color(0xFFFACC15), 'MEDIUM'],
      SeverityScore.low:      [const Color(0xFF38BDF8), 'LOW'],
    };
    final color = map[severity]![0] as Color;
    final label = map[severity]![1] as String;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withOpacity(0.2), borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  final AlertType alertType;
  const _TypeBadge({required this.alertType});

  @override
  Widget build(BuildContext context) {
    final Map<AlertType, List<dynamic>> map = {
      AlertType.fire:       [Icons.local_fire_department, Colors.orange],
      AlertType.flood:      [Icons.water, Colors.blue],
      AlertType.injury:     [Icons.medical_services, Colors.red],
      AlertType.trapped:    [Icons.warning, Colors.deepOrange],
      AlertType.missing:    [Icons.person_search, Colors.purple],
      AlertType.earthquake: [Icons.crisis_alert, Colors.amber],
      AlertType.general:    [Icons.info, Colors.grey],
    };
    final icon = map[alertType]![0] as IconData;
    final color = map[alertType]![1] as Color;
    return Icon(icon, color: color.withOpacity(0.8), size: 16);
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MetaChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: Colors.white38),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 10)),
        ],
      ),
    );
  }
}

// =============================================================
// TAB 2 — SOS: Create & broadcast an alert
// =============================================================
class _TriageTab extends StatefulWidget {
  final void Function(Alert alert) onAlertCreated;
  const _TriageTab({required this.onAlertCreated});

  @override
  State<_TriageTab> createState() => _TriageTabState();
}

enum _VerificationState { unknown, verifying, verified, failed }

class _TriageTabState extends State<_TriageTab> {
  final TextEditingController _controller = TextEditingController();
  TriageResult? _result;
  _VerificationState _verificationState = _VerificationState.unknown;
  String _verificationMessage = 'Enter emergency details to verify the SOS request.';
  String? _imagePath;
  bool _isScanningImage = false;

  Future<void> _pickImage(ImageSource source) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: source);
    if (image == null) return;

    setState(() {
      _imagePath = image.path;
      _isScanningImage = true;
    });

    // Run offline image detection
    final String labels = await OfflineImageScanner.scanEmergencyImage(image.path);

    setState(() {
      _isScanningImage = false;
      if (labels.isNotEmpty) {
        // Append labels to the description
        final currentText = _controller.text.trim();
        _controller.text = currentText.isEmpty 
            ? 'Detected from image: [$labels]' 
            : '$currentText\nDetected from image: [$labels]';
        _analyze(); // Re-trigger triage analysis
      }
    });
  }

  void _analyze() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) {
      setState(() => _result = AITriageService.evaluateEmergency(text));
      _verifyMessage(text);
    } else {
      setState(() {
        _result = null;
        _verificationState = _VerificationState.unknown;
        _verificationMessage = 'Enter emergency details to verify the SOS request.';
      });
    }
  }

  Future<void> _verifyMessage(String text) async {
    if (text.isEmpty) {
      setState(() {
        _verificationState = _VerificationState.unknown;
        _verificationMessage = 'Enter emergency details to verify the SOS request.';
      });
      return;
    }

    setState(() {
      _verificationState = _VerificationState.verifying;
      _verificationMessage = 'Verifying SOS request...';
    });

    try {
      final verified = await DisasterVerifier.instance.verifySOS(text);
      setState(() {
        _verificationState = verified ? _VerificationState.verified : _VerificationState.failed;
        _verificationMessage = verified
            ? 'SOS request verified by local disaster model.'
            : 'Verification failed. Add clearer emergency details before broadcast.';
      });
    } catch (error) {
      setState(() {
        _verificationState = _VerificationState.failed;
        _verificationMessage =
            'Verification error: could not verify local model. Check asset availability.';
      });
    }
  }

  void _broadcast() {
    if (_verificationState != _VerificationState.verified) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _verificationState == _VerificationState.verifying
                ? 'Please wait until SOS verification completes.'
                : 'SOS request must be verified before upload.',
          ),
          backgroundColor: const Color(0xFFF43F5E),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final mesh = context.read<MeshService>();
    final locationSvc = context.read<LocationService>();
    final result = _result!;
    
    final lat = locationSvc.currentPosition?.latitude ?? 12.9716;
    final lng = locationSvc.currentPosition?.longitude ?? 77.5946;

    final alert = Alert(
      id: 'alert_${DateTime.now().millisecondsSinceEpoch}',
      originNodeId: mesh.localNodeId,
      senderId: mesh.localNodeId,
      alertType: result.alertType,
      description: _controller.text.trim(),
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
      severity: result.severity,
      action: result.action,
      hopCount: 0,
      ttl: 15,
    );
    widget.onAlertCreated(alert);
    _controller.clear();
    setState(() => _result = null);
  }

  Color _severityColor(SeverityScore s) {
    switch (s) {
      case SeverityScore.critical: return const Color(0xFFF43F5E);
      case SeverityScore.high:     return const Color(0xFFF97316);
      case SeverityScore.medium:   return const Color(0xFFFACC15);
      case SeverityScore.low:      return const Color(0xFF38BDF8);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Send Emergency Alert', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(height: 6),
                  Text(
                    'Describe the emergency. Edge AI triages it instantly, then one tap chains it through every nearby phone.',
                    style: TextStyle(color: Colors.white.withOpacity(0.5), height: 1.5),
                  ),
                  const SizedBox(height: 24),

                  // Description input
                  TextField(
                    controller: _controller,
                    maxLines: 5,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                    onChanged: (_) => _analyze(),
                    decoration: InputDecoration(
                      hintText: 'e.g. There is a fire and a person is trapped under debris...',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.25)),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: Color(0xFF38BDF8), width: 1.5),
                      ),
                      contentPadding: const EdgeInsets.all(16),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Attach Image Button
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _isScanningImage ? null : () => _pickImage(ImageSource.camera),
                        icon: const Icon(Icons.camera_alt, size: 16),
                        label: const Text('Take Photo'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _isScanningImage ? null : () => _pickImage(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library, size: 16),
                        label: const Text('Gallery'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24),
                        ),
                      ),
                    ],
                  ),
                  
                  if (_isScanningImage) ...[
                    const SizedBox(height: 12),
                    const Row(
                      children: [
                        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 12),
                        Text('Running offline AI vision...', style: TextStyle(color: Colors.white54, fontSize: 13)),
                      ],
                    ),
                  ],
                  if (_imagePath != null && !_isScanningImage) ...[
                    const SizedBox(height: 12),
                    Container(
                      height: 100,
                      width: 100,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        image: DecorationImage(
                          image: FileImage(File(_imagePath!)),
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ],
                  
                  const SizedBox(height: 20),

                  // AI triage result card
                  if (_result != null) ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [_severityColor(_result!.severity).withOpacity(0.12), const Color(0xFF1E293B)],
                          begin: Alignment.topLeft, end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _severityColor(_result!.severity).withOpacity(0.4)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Icon(Icons.auto_awesome, color: _severityColor(_result!.severity), size: 16),
                            const SizedBox(width: 8),
                            const Text('Edge AI Analysis', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            const Spacer(),
                            _SeverityBadge(severity: _result!.severity),
                          ]),
                          const SizedBox(height: 12),
                          Text(_result!.action,
                              style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 13, height: 1.5)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        if (_verificationState == _VerificationState.verifying)
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF38BDF8)),
                          )
                        else
                          Icon(
                            _verificationState == _VerificationState.verified ? Icons.check_circle : Icons.error_outline,
                            color: _verificationState == _VerificationState.verified ? Color(0xFF22C55E) : Color(0xFFFBBF24),
                            size: 18,
                          ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _verificationMessage,
                            style: TextStyle(
                              color: _verificationState == _VerificationState.failed
                                  ? Colors.orange.shade200
                                  : Colors.white.withOpacity(0.8),
                              fontSize: 13,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ],
                ],
              ),
            ),
          ),

          // SOS Broadcast Button (pinned to bottom)
          SizedBox(
            width: double.infinity,
            height: 60,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.send_rounded, color: Colors.white),
              label: const Text(
                'BROADCAST TO MESH',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 1, color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _result != null && _verificationState == _VerificationState.verified
                    ? const Color(0xFFF43F5E)
                    : Colors.grey.shade800,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                elevation: _result != null && _verificationState == _VerificationState.verified ? 8 : 0,
                shadowColor: const Color(0xFFF43F5E).withOpacity(0.5),
              ),
              onPressed: _result != null && _verificationState == _VerificationState.verified ? _broadcast : null,
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

// =============================================================
// TAB 3 — Chain Relay Log
// =============================================================
class _RelayLogTab extends StatelessWidget {
  const _RelayLogTab();

  @override
  Widget build(BuildContext context) {
    return Consumer<MeshService>(
      builder: (context, mesh, _) {
        final logs = mesh.relayLog.reversed.toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
              child: Row(
                children: [
                  const Text('Chain Relay Log', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('${mesh.totalRelayCount} total',
                      style: const TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            if (logs.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.account_tree_outlined, color: Colors.white24, size: 56),
                      const SizedBox(height: 16),
                      const Text('No relays yet', style: TextStyle(color: Colors.white38)),
                      const SizedBox(height: 8),
                      const Text('Broadcast an alert to see the chain reaction here.',
                          style: TextStyle(color: Colors.white24, fontSize: 12), textAlign: TextAlign.center),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: logs.length,
                  itemBuilder: (ctx, i) {
                    final log = logs[i];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 28, height: 28,
                            decoration: BoxDecoration(
                              color: const Color(0xFF38BDF8).withOpacity(0.15),
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text('${log.hopNumber}',
                                  style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${log.fromNodeId} → ${log.toNodeId}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'monospace'),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Alert: ${log.alertId.substring(0, min(log.alertId.length, 16))}...',
                                  style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 10),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.arrow_forward_rounded, color: Color(0xFF38BDF8), size: 14),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}


// =============================================================
// TAB 3 — Live Locations Map (flutter_map + tile caching)
// Tiles cached on device — works offline after first load.
// Shows peers and victims, and draws shortest path online.
// =============================================================
class _LocationsMapTab extends StatefulWidget {
  final List<Alert> alerts;
  const _LocationsMapTab({required this.alerts});

  @override
  State<_LocationsMapTab> createState() => _LocationsMapTabState();
}

class _LocationsMapTabState extends State<_LocationsMapTab> {
  final MapController _mapController = MapController();
  bool _showList = false;
  bool _centred = false; // auto-centre once on first GPS fix

  Alert? _selectedAlert;
  List<LatLng> _routePoints = [];
  bool _isFetchingRoute = false;

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  void _centreOnMe(double lat, double lng) {
    _mapController.move(LatLng(lat, lng), 16.0);
  }

  Future<void> _fetchRoute(double myLat, double myLng, double victimLat, double victimLng) async {
    if (_isFetchingRoute) return;
    setState(() {
      _isFetchingRoute = true;
      _routePoints = [];
    });

    try {
      // Use OSRM public API for routing
      final url = Uri.parse('https://router.project-osrm.org/route/v1/driving/$myLng,$myLat;$victimLng,$victimLat?overview=full&geometries=geojson');
      final response = await http.get(url).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final coords = data['routes'][0]['geometry']['coordinates'] as List;
          setState(() {
            _routePoints = coords.map((c) => LatLng(c[1] as double, c[0] as double)).toList();
          });
        }
      }
    } catch (e) {
      debugPrint('OSRM routing failed: $e');
    } finally {
      if (mounted) setState(() => _isFetchingRoute = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<MeshService, LocationService>(
      builder: (context, mesh, locationSvc, _) {
        final locations = mesh.userLocations.values.toList();
        final myPos = locationSvc.currentPosition;

        // Auto-centre map on first GPS fix
        if (!_centred && myPos != null) {
          _centred = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _mapController.move(LatLng(myPos.latitude, myPos.longitude), 16.0);
          });
        }

        // Default centre: my GPS or Bangalore fallback
        final double initLat = myPos?.latitude ?? 12.9716;
        final double initLng = myPos?.longitude ?? 77.5946;

        return Column(
          children: [
            // ── Header ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Row(
                children: [
                  const Text('Live Map',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('${locations.length}',
                        style: const TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: _showList ? 'Show Map' : 'Show List',
                    icon: Icon(_showList ? Icons.map_outlined : Icons.list_rounded,
                        color: const Color(0xFF38BDF8)),
                    onPressed: () => setState(() => _showList = !_showList),
                  ),
                ],
              ),
            ),

            // ── Permission warning ───────────────────────────
            if (!locationSvc.hasPermission)
              _PermissionBanner(
                message: locationSvc.errorMessage ?? 'Location permission required.',
                onRetry: () async {
                  await locationSvc.requestPermission();
                  if (locationSvc.hasPermission) locationSvc.startTracking();
                },
              ),

            // ── GPS coordinates bar ──────────────────────────
            if (myPos != null) _MyLocationBar(position: myPos),

            // ── Map or List ──────────────────────────────────
            Expanded(
              child: _showList
                  ? _buildList(mesh, locations, myPos)
                  : _buildMap(mesh, locations, myPos, initLat, initLng),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMap(MeshService mesh, List<UserLocation> locations,
      dynamic myPos, double initLat, double initLng) {
    // Build markers
    final List<Marker> markers = [];

    // My location marker
    if (myPos != null) {
      markers.add(Marker(
        point: LatLng(myPos.latitude, myPos.longitude),
        width: 60,
        height: 70,
        child: _MyMarker(
          lat: myPos.latitude,
          lng: myPos.longitude,
        ),
      ));
    }

    // Peer markers
    for (final loc in locations) {
      if (loc.userId == mesh.localNodeId) continue;
      final distM = myPos != null
          ? Geolocator.distanceBetween(
              myPos.latitude, myPos.longitude, loc.latitude, loc.longitude)
          : null;
      markers.add(Marker(
        point: LatLng(loc.latitude, loc.longitude),
        width: 120,
        height: 80,
        child: _PeerMarker(
          name: loc.userName,
          distM: distM,
          lat: loc.latitude,
          lng: loc.longitude,
        ),
      ));
    }

    // Victim (Alert) markers
    for (final alert in widget.alerts) {
      if (alert.latitude == null || alert.longitude == null) continue;
      final distM = myPos != null
          ? Geolocator.distanceBetween(
              myPos.latitude, myPos.longitude, alert.latitude!, alert.longitude!)
          : null;
      final isSelected = _selectedAlert?.id == alert.id;
      final senderName = alert.originNodeId == mesh.localNodeId 
          ? 'YOU' 
          : (mesh.userLocations[alert.originNodeId]?.userName ?? 'Unknown');
      
      markers.add(Marker(
        point: LatLng(alert.latitude!, alert.longitude!),
        width: 120,
        height: 80,
        child: GestureDetector(
          onTap: () {
            setState(() {
              _selectedAlert = alert;
            });
            if (myPos != null) {
              _fetchRoute(myPos.latitude, myPos.longitude, alert.latitude!, alert.longitude!);
            }
          },
          child: _VictimMarker(
            alertType: alert.alertType.name,
            distM: distM,
            isSelected: isSelected,
            senderName: senderName,
          ),
        ),
      ));
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: LatLng(initLat, initLng),
            initialZoom: 15.0,
            minZoom: 3.0,
            maxZoom: 19.0,
            backgroundColor: const Color(0xFF0F172A),
          ),
          children: [
            // ── Tile layer with disk cache ───────────────────
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.resqmesh.resqmesh_mobile',
              tileProvider: CachedTileProvider(),
              maxZoom: 19,
              // Show cached tiles while loading new ones
              keepBuffer: 5,
              panBuffer: 2,
            ),
            // ── Accuracy circle around my position ──────────
            if (myPos != null)
              CircleLayer(circles: [
                CircleMarker(
                  point: LatLng(myPos.latitude, myPos.longitude),
                  radius: myPos.accuracy ?? 20,
                  useRadiusInMeter: true,
                  color: const Color(0xFF38BDF8).withOpacity(0.12),
                  borderColor: const Color(0xFF38BDF8).withOpacity(0.5),
                  borderStrokeWidth: 1.5,
                ),
              ]),
            // ── Route Polyline ───────────────────────────────
            if (_routePoints.isNotEmpty)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _routePoints,
                    strokeWidth: 4.0,
                    color: const Color(0xFFF43F5E),
                    isDotted: true,
                  ),
                ],
              ),
            // ── Markers ──────────────────────────────────────
            MarkerLayer(markers: markers),
          ],
        ),

        // ── Centre-on-me FAB ─────────────────────────────────
        Positioned(
          bottom: 80,
          right: 16,
          child: _MapFab(
            icon: Icons.my_location,
            tooltip: 'Centre on me',
            onTap: () {
              if (myPos != null) _centreOnMe(myPos.latitude, myPos.longitude);
            },
          ),
        ),

        // ── Offline notice (shown when no tiles loaded) ──────
        Positioned(
          bottom: 16,
          left: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B).withOpacity(0.88),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white12),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.offline_bolt, color: Color(0xFF38BDF8), size: 12),
                SizedBox(width: 5),
                Text('Tiles cached for offline use',
                    style: TextStyle(color: Colors.white38, fontSize: 10)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildList(MeshService mesh, List<UserLocation> locations, dynamic myPos) {
    if (locations.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_off_outlined, color: Colors.white24, size: 64),
            SizedBox(height: 16),
            Text('No locations shared yet', style: TextStyle(color: Colors.white54, fontSize: 16)),
            SizedBox(height: 8),
            Text('Activate mesh to start sharing locations',
                style: TextStyle(color: Colors.white24, fontSize: 12), textAlign: TextAlign.center),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: locations.length,
      itemBuilder: (ctx, i) {
        final loc = locations[i];
        final isLocal = loc.userId == mesh.localNodeId;
        final myLoc = mesh.userLocations[mesh.localNodeId];
        final distance = myLoc != null
            ? Geolocator.distanceBetween(
                myLoc.latitude, myLoc.longitude, loc.latitude, loc.longitude)
            : 0.0;

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isLocal
                  ? const Color(0xFF38BDF8).withOpacity(0.4)
                  : const Color(0xFF10B981).withOpacity(0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isLocal
                          ? const Color(0xFF38BDF8).withOpacity(0.2)
                          : const Color(0xFF10B981).withOpacity(0.15),
                    ),
                    child: Icon(
                      isLocal ? Icons.my_location : Icons.person_pin_circle,
                      color: isLocal ? const Color(0xFF38BDF8) : const Color(0xFF10B981),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(loc.userName,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                        if (isLocal)
                          const Text('This device',
                              style: TextStyle(color: Color(0xFF38BDF8), fontSize: 11)),
                      ],
                    ),
                  ),
                  if (!isLocal)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        distance >= 1000
                            ? '${(distance / 1000).toStringAsFixed(2)}km'
                            : '${distance.toStringAsFixed(1)}m',
                        style: const TextStyle(
                            color: Color(0xFF10B981), fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Icon(Icons.location_on_outlined, color: Colors.grey, size: 14),
                        Text(
                          '${loc.latitude.toStringAsFixed(6)}°,  ${loc.longitude.toStringAsFixed(6)}°',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.7),
                              fontSize: 11,
                              fontFamily: 'monospace'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Icon(Icons.schedule, color: Colors.grey, size: 14),
                        Text(_formatTime(loc.timestamp),
                            style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 10)),
                      ],
                    ),
                    if (loc.accuracy != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Icon(Icons.gps_fixed, color: Colors.grey, size: 14),
                          Text('Accuracy ±${loc.accuracy!.toStringAsFixed(0)}m',
                              style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 10)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () {
                  setState(() => _showList = false);
                  Future.delayed(const Duration(milliseconds: 150), () {
                    _mapController.move(LatLng(loc.latitude, loc.longitude), 17.0);
                  });
                },
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.map_outlined, color: Color(0xFF38BDF8), size: 13),
                    SizedBox(width: 4),
                    Text('Show on map',
                        style: TextStyle(color: Color(0xFF38BDF8), fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

// ── My location marker (blue pulsing dot) ─────────────────────
class _MyMarker extends StatelessWidget {
  final double lat;
  final double lng;
  const _MyMarker({required this.lat, required this.lng});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withOpacity(0.9),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF38BDF8), width: 1),
          ),
          child: Text(
            'YOU\n${lat.toStringAsFixed(5)}°\n${lng.toStringAsFixed(5)}°',
            style: const TextStyle(
                color: Color(0xFF38BDF8), fontSize: 8, fontWeight: FontWeight.bold, height: 1.3),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 2),
        Container(
          width: 16, height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF38BDF8),
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(color: const Color(0xFF38BDF8).withOpacity(0.6), blurRadius: 8, spreadRadius: 2),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Peer marker (green pin with name + distance) ───────────────
class _PeerMarker extends StatelessWidget {
  final String name;
  final double? distM;
  final double lat;
  final double lng;
  const _PeerMarker({required this.name, required this.distM, required this.lat, required this.lng});

  @override
  Widget build(BuildContext context) {
    final distLabel = distM == null
        ? ''
        : distM! >= 1000
            ? '${(distM! / 1000).toStringAsFixed(2)}km'
            : '${distM!.toStringAsFixed(1)}m';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withOpacity(0.92),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: const Color(0xFF10B981), width: 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name.length > 12 ? '${name.substring(0, 12)}…' : name,
                style: const TextStyle(
                    color: Color(0xFF10B981), fontSize: 9, fontWeight: FontWeight.bold),
              ),
              if (distLabel.isNotEmpty) ...[
                const SizedBox(height: 1),
                Text(distLabel,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
              ],
              Text(
                '${lat.toStringAsFixed(4)}°, ${lng.toStringAsFixed(4)}°',
                style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 7),
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Container(
          width: 14, height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF10B981),
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(color: const Color(0xFF10B981).withOpacity(0.5), blurRadius: 6, spreadRadius: 1),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Victim marker (red pulsing pin for alerts) ────────────────
class _VictimMarker extends StatelessWidget {
  final String alertType;
  final double? distM;
  final bool isSelected;
  final String senderName;
  const _VictimMarker({required this.alertType, required this.distM, this.isSelected = false, required this.senderName});

  @override
  Widget build(BuildContext context) {
    final distLabel = distM == null
        ? ''
        : distM! >= 1000
            ? '${(distM! / 1000).toStringAsFixed(2)}km'
            : '${distM!.toStringAsFixed(1)}m';

    final color = isSelected ? const Color(0xFFE11D48) : const Color(0xFFF43F5E); // Rose

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withOpacity(0.92),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: color, width: isSelected ? 2 : 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'VICTIM: ${alertType.toUpperCase()}',
                style: TextStyle(
                    color: color, fontSize: 9, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 1),
              Text(
                senderName,
                style: const TextStyle(
                    color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
              ),
              if (distLabel.isNotEmpty) ...[
                const SizedBox(height: 1),
                Text(distLabel,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 2),
        Container(
          width: isSelected ? 18 : 14, 
          height: isSelected ? 18 : 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(color: color.withOpacity(isSelected ? 0.8 : 0.5), blurRadius: 6, spreadRadius: isSelected ? 2 : 1),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Map FAB button ─────────────────────────────────────────────
class _MapFab extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _MapFab({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44, height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white12),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 8)],
        ),
        child: Icon(icon, color: const Color(0xFF38BDF8), size: 22),
      ),
    );
  }
}

// ── Permission Banner ──────────────────────────────────────────
class _PermissionBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _PermissionBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF97316).withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF97316).withOpacity(0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.location_off, color: Color(0xFFF97316), size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(color: Colors.white70, fontSize: 12))),
          TextButton(
            onPressed: onRetry,
            child: const Text('Enable', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

// ── My Location Status Bar ─────────────────────────────────────
class _MyLocationBar extends StatelessWidget {
  final dynamic position;
  const _MyLocationBar({required this.position});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF38BDF8).withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF38BDF8).withOpacity(0.2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.gps_fixed, color: Color(0xFF38BDF8), size: 14),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${position.latitude.toStringAsFixed(6)}°,  ${position.longitude.toStringAsFixed(6)}°',
              style: const TextStyle(
                  color: Color(0xFF38BDF8), fontSize: 12,
                  fontFamily: 'monospace', fontWeight: FontWeight.bold),
            ),
          ),
          Text('±${position.accuracy.toStringAsFixed(0)}m',
              style: const TextStyle(color: Colors.white38, fontSize: 10)),
        ],
      ),
    );
  }
}

