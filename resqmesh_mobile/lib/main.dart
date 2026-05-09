import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/mesh_service.dart';
import 'services/gateway_service.dart';
import 'services/location_service.dart';
import 'services/cached_tile_provider.dart';
import 'ui/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CachedTileProvider.init(); // Set up tile cache directory

  // Each device gets a unique name so Nearby Connections can distinguish them
  final deviceName = 'ResQ_${Random().nextInt(9000) + 1000}';

  // Build MeshService first so we have its nodeId
  final mesh = MeshService(userName: deviceName);

  // Build GatewayService, wire its downlink callback to inject into the mesh
  final gateway = GatewayService(
    nodeId: mesh.localNodeId,
    onServerAlert: (alert) {
      // Server pushed an alert → inject into local BT mesh
      mesh.injectCloudAlert(alert);
    },
    onServerLocation: (location) {
      // Server pushed a peer location → inject into local BT mesh
      mesh.injectCloudLocation(location);
    },
  );

  // Give MeshService a reference to GatewayService for uplink calls
  mesh.gateway = gateway;
  // Give GatewayService a reference to MeshService for immediate location push on connect
  gateway.mesh = mesh;

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: mesh),
        ChangeNotifierProvider.value(value: gateway),
        ChangeNotifierProvider(create: (_) => LocationService()),
      ],
      child: const ResQMeshApp(),
    ),
  );
}

class ResQMeshApp extends StatelessWidget {
  const ResQMeshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ResQMesh',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFF0F172A),
        scaffoldBackgroundColor: const Color(0xFF0F172A), // Slate 900
        cardColor: const Color(0xFF1E293B),               // Slate 800
        fontFamily: 'Inter',
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),    // Sky 400
          secondary: Color(0xFFF43F5E), // Rose 500
          surface: Color(0xFF1E293B),
        ),
      ),
      home: const _AppStartup(),
    );
  }
}

/// Requests location permission on first launch, then shows HomeScreen.
class _AppStartup extends StatefulWidget {
  const _AppStartup();

  @override
  State<_AppStartup> createState() => _AppStartupState();
}

class _AppStartupState extends State<_AppStartup> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final locationService = context.read<LocationService>();
    final mesh = context.read<MeshService>();

    await locationService.requestPermission();
    if (locationService.hasPermission) {
      locationService.startTracking();
      // Start broadcasting our location immediately — no Bluetooth required.
      // This ensures cloud-connected devices are always visible on the map.
      mesh.startLocationBroadcast();
    }
    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        backgroundColor: Color(0xFF0F172A),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF38BDF8)),
              SizedBox(height: 20),
              Text(
                'Initializing ResQMesh...',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }
    return const HomeScreen();
  }
}
