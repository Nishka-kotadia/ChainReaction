import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

import 'ai_triage.dart';
import 'models.dart';

/// Verifies a SOS request before upload using local disaster model inference.
///
/// This is an offline guard that protects against accidental or non-emergency
/// SOS broadcasts by requiring either a strong text signal or an image-based
/// hazard prediction from the disaster model.
class DisasterVerifier {
  static const String _modelAsset =
      'assets/models/disaster_mobilenetv3/disaster_mobilenetv3_int8.onnx';
  static const String _metadataAsset =
      'assets/models/disaster_mobilenetv3/disaster_mobilenetv3_metadata.json';

  static final DisasterVerifier instance = DisasterVerifier._();

  late OrtSession _session;
  late Map<String, dynamic> _metadata;
  bool _loaded = false;

  DisasterVerifier._();

  Future<void> loadModel() async {
    if (_loaded) return;

    OrtEnv.instance.init();
    final modelBytes = await rootBundle.load(_modelAsset);
    _session = OrtSession.fromBuffer(
      modelBytes.buffer.asUint8List(),
      OrtSessionOptions(),
    );

    final metaStr = await rootBundle.loadString(_metadataAsset);
    _metadata = json.decode(metaStr) as Map<String, dynamic>;
    _loaded = true;
  }

  Future<Map<String, double>> classifyImage(Uint8List imageBytes) async {
    await loadModel();

    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      throw Exception('Unable to decode image for SOS verification.');
    }

    final inputSize = _metadata['input_size'] as List<dynamic>;
    final int height = inputSize[0] as int;
    final int width = inputSize[1] as int;

    final Float32List pixels = _preprocessImage(decoded, height, width);
    final inputTensor = OrtValueTensor.createTensorWithDataList(
      pixels,
      [1, 3, height, width],
    );

    final outputs = await _session.runAsync(
      OrtRunOptions(),
      {'input': inputTensor},
    );

    final dynamic raw = outputs![0]!.value;
    final List<double> logits;
    if (raw is List && raw.isNotEmpty && raw.first is List) {
      logits = (raw.first as List).cast<double>();
    } else if (raw is List) {
      logits = raw.cast<double>();
    } else {
      throw Exception('Unexpected model output shape during verification.');
    }

    final probs = _softmax(logits);
    final id2label = Map<String, dynamic>.from(_metadata['id2label'] as Map);
    return {
      for (var i = 0; i < probs.length; i++)
        id2label[i.toString()] as String: probs[i],
    };
  }

  Float32List _preprocessImage(img.Image image, int height, int width) {
    final resized = img.copyResize(image, width: width, height: height);
    final mean = (_metadata['preprocessing']['mean'] as List<dynamic>)
        .map((e) => e as double)
        .toList();
    final std = (_metadata['preprocessing']['std'] as List<dynamic>)
        .map((e) => e as double)
        .toList();
    final scale = _metadata['preprocessing']['rescale_factor'] as double;

    final buffer = Float32List(3 * height * width);
    for (var c = 0; c < 3; c++) {
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final pixel = resized.getPixel(x, y);
          final raw = c == 0
              ? pixel.r
              : c == 1
                  ? pixel.g
                  : pixel.b;
          final normalized = (raw.toDouble() * scale - mean[c]) / std[c];
          buffer[c * height * width + y * width + x] = normalized;
        }
      }
    }
    return buffer;
  }

  List<double> _softmax(List<double> logits) {
    final maxValue = logits.reduce(math.max);
    final exps = logits.map((value) => math.exp(value - maxValue)).toList();
    final sum = exps.reduce((value, element) => value + element);
    return exps.map((value) => value / sum).toList();
  }

  Future<bool> verifySOS(String description, {Uint8List? imageBytes}) async {
    if (imageBytes != null) {
      final results = await classifyImage(imageBytes);
      final topEntry = results.entries
          .reduce((a, b) => a.value >= b.value ? a : b);
      return topEntry.key != 'normal' && topEntry.value >= 0.55;
    }

    final lower = description.toLowerCase();
    final List<String> nonEmergencyPhrases = [
      'not an emergency',
      'no emergency',
      'not emergency',
      'false alarm',
      'no danger',
      'just a drill',
      'not urgent',
    ];

    if (nonEmergencyPhrases.any(lower.contains)) {
      return false;
    }

    final List<String> emergencyKeywords = [
      'sos',
      'help',
      'emergency',
      'urgent',
      'fire',
      'smoke',
      'trapped',
      'collapse',
      'flood',
      'injury',
      'missing',
      'medical',
    ];

    if (emergencyKeywords.any(lower.contains)) {
      return true;
    }

    final triage = AITriageService.evaluateEmergency(description);
    // Only broadcast if the triage result is medium or higher severity.
    // Low-severity descriptions are treated as non-emergencies.
    return triage.severity.index >= SeverityScore.medium.index;
  }
}
