import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

// ============================================================
// ResQMesh — Offline-capable Tile Provider
//
// Wraps flutter_map's NetworkTileProvider with a custom HTTP
// client that:
//   1. Checks disk cache first (serves instantly, no network)
//   2. Fetches from OSM if not cached or stale
//   3. Falls back to stale cache when offline
//
// Cache: <tmpDir>/map_tiles/<z>/<x>/<y>.png  (30-day TTL)
// ============================================================

class CachedTileProvider extends TileProvider {
  static const Duration _maxAge = Duration(days: 30);
  static Directory? _cacheDir;

  /// Call once at app startup (after WidgetsFlutterBinding.ensureInitialized)
  static Future<void> init() async {
    final base = await getTemporaryDirectory();
    _cacheDir = Directory('${base.path}/map_tiles');
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }
    debugPrint('🗺️ TileCache: ${_cacheDir!.path}');
  }

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = getTileUrl(coordinates, options);
    return _CachedNetworkImage(
      url: url,
      coordinates: coordinates,
      cacheDir: _cacheDir,
      maxAge: _maxAge,
      headers: headers,
    );
  }
}

// ── Custom ImageProvider with disk cache ──────────────────────
class _CachedNetworkImage extends ImageProvider<_CachedNetworkImage> {
  final String url;
  final TileCoordinates coordinates;
  final Directory? cacheDir;
  final Duration maxAge;
  final Map<String, String> headers;

  const _CachedNetworkImage({
    required this.url,
    required this.coordinates,
    required this.cacheDir,
    required this.maxAge,
    required this.headers,
  });

  File? get _file {
    if (cacheDir == null) return null;
    final z = coordinates.z.round();
    return File('${cacheDir!.path}/$z/${coordinates.x}/${coordinates.y}.png');
  }

  @override
  Future<_CachedNetworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
      _CachedNetworkImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key).then((bytes) async {
        final buffer = await ImmutableBuffer.fromUint8List(bytes);
        return decode(buffer);
      }),
      scale: 1.0,
      informationCollector: () => [DiagnosticsProperty('URL', key.url)],
    );
  }

  Future<Uint8List> _load(_CachedNetworkImage key) async {
    final file = key._file;

    // 1. Fresh cache hit
    if (file != null && await file.exists()) {
      final age = DateTime.now().difference((await file.stat()).modified);
      if (age < key.maxAge) {
        return file.readAsBytes();
      }
    }

    // 2. Network fetch
    try {
      final response = await http.get(
        Uri.parse(key.url),
        headers: {
          ...key.headers,
          'User-Agent': 'ResQMesh/1.0 (emergency mesh; contact@resqmesh.app)',
        },
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;
        if (file != null) {
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes);
        }
        return bytes;
      }
    } catch (_) {
      // Network unavailable — fall through to stale cache
    }

    // 3. Stale cache fallback (offline mode)
    if (file != null && await file.exists()) {
      debugPrint('🗺️ Offline fallback: ${key.url}');
      return file.readAsBytes();
    }

    // 4. Transparent 1×1 PNG placeholder
    return Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]);
  }

  @override
  bool operator ==(Object other) =>
      other is _CachedNetworkImage && url == other.url;

  @override
  int get hashCode => url.hashCode;
}

