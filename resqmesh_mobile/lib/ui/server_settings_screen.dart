import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/gateway_service.dart';

// ================================================================
// ResQMesh — Server Settings Screen
// Lets rescue coordinators change the server URL at runtime
// without needing to rebuild or reinstall the app.
// ================================================================

class ServerSettingsScreen extends StatefulWidget {
  const ServerSettingsScreen({super.key});

  @override
  State<ServerSettingsScreen> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends State<ServerSettingsScreen> {
  late TextEditingController _urlController;
  bool _isSaving = false;
  bool _isTesting = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    final gw = context.read<GatewayService>();
    _urlController = TextEditingController(text: gw.serverUrl);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_urlController.text.trim().isEmpty) return;
    setState(() => _isSaving = true);
    await context.read<GatewayService>().updateServerUrl(_urlController.text);
    if (mounted) {
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Server URL updated. Reconnecting...'),
          backgroundColor: Color(0xFF38BDF8),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _test() async {
    setState(() {
      _isTesting = true;
      _testResult = null;
    });
    final status = await context.read<GatewayService>().fetchServerStatus();
    if (mounted) {
      setState(() {
        _isTesting = false;
        _testResult = status != null
            ? '✅ Connected — ${status['connectedClients']} devices online, ${status['totalAlertsRelayed']} alerts relayed'
            : '❌ Cannot reach server. Check URL and internet.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final gw = context.watch<GatewayService>();

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Server Settings', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Status card ──────────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: gw.isConnected ? Colors.blueAccent.withOpacity(0.4) : Colors.grey.withOpacity(0.2),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: gw.isConnected ? Colors.blueAccent : gw.hasInternet ? Colors.orangeAccent : Colors.grey,
                      boxShadow: gw.isConnected
                          ? [BoxShadow(color: Colors.blueAccent.withOpacity(0.5), blurRadius: 8, spreadRadius: 2)]
                          : [],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          gw.isConnected
                              ? 'CONNECTED TO SERVER'
                              : gw.hasInternet
                                  ? 'CONNECTING...'
                                  : 'NO INTERNET',
                          style: TextStyle(
                            color: gw.isConnected ? Colors.blueAccent : gw.hasInternet ? Colors.orangeAccent : Colors.grey,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            letterSpacing: 1,
                          ),
                        ),
                        if (gw.isConnected) ...[
                          const SizedBox(height: 2),
                          Text(
                            '${gw.globalConnectedCount} devices connected globally',
                            style: const TextStyle(color: Colors.white70, fontSize: 13),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 28),

            // ── URL input ────────────────────────────────────────
            const Text(
              'SERVER URL',
              style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlController,
              style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: 'https://resqmesh.loca.lt',
                hintStyle: TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF1E293B),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white12),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF38BDF8)),
                ),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear, color: Colors.white38),
                  onPressed: () => _urlController.clear(),
                ),
              ),
              autocorrect: false,
              keyboardType: TextInputType.url,
            ),

            const SizedBox(height: 8),
            Text(
              'Enter the public URL of the ResQMesh server.\nWorks with any internet (mobile data, Wi-Fi, etc.)',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),

            const SizedBox(height: 20),

            // ── Buttons ──────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: _isTesting
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54))
                        : const Icon(Icons.wifi_find, size: 18),
                    label: Text(_isTesting ? 'Testing...' : 'Test Connection'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _isTesting ? null : _test,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: _isSaving
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.save, size: 18),
                    label: Text(_isSaving ? 'Saving...' : 'Save & Connect'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF38BDF8),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _isSaving ? null : _save,
                  ),
                ),
              ],
            ),

            // ── Test result ──────────────────────────────────────
            if (_testResult != null) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _testResult!.startsWith('✅')
                      ? Colors.green.withOpacity(0.1)
                      : Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _testResult!.startsWith('✅')
                        ? Colors.green.withOpacity(0.3)
                        : Colors.red.withOpacity(0.3),
                  ),
                ),
                child: Text(
                  _testResult!,
                  style: TextStyle(
                    color: _testResult!.startsWith('✅') ? Colors.greenAccent : Colors.redAccent,
                    fontSize: 13,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 28),
            const Divider(color: Colors.white12),
            const SizedBox(height: 16),

            // ── Reset to default ─────────────────────────────────
            TextButton.icon(
              icon: const Icon(Icons.restore, size: 18, color: Colors.white38),
              label: const Text('Reset to Default URL', style: TextStyle(color: Colors.white38)),
              onPressed: () {
                _urlController.text = GatewayService.defaultServerUrl;
              },
            ),

            const SizedBox(height: 8),

            // ── Quick reference ──────────────────────────────────
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.03),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Quick URLs', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 8),
                  _quickUrl('Local LAN (same Wi-Fi)', 'http://10.10.0.17:3000'),
                  _quickUrl('Public Tunnel (any network)', 'https://resqmesh.loca.lt'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickUrl(String label, String url) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                Text(url, style: const TextStyle(color: Colors.white60, fontSize: 12, fontFamily: 'monospace')),
              ],
            ),
          ),
          TextButton(
            child: const Text('Use', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 12)),
            onPressed: () => _urlController.text = url,
          ),
        ],
      ),
    );
  }
}
