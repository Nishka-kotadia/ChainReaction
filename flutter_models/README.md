# Disaster Detection ONNX Models — Flutter Integration

Pre-exported ONNX models for offline disaster detection in a Flutter app.

## Models

| Folder | Description | Classes |
|--------|-------------|---------|
| `fire_smoke/` | Fire & smoke detection | fire, normal, smoke |
| `flood/` | Flood scene detection | Flooded Scene, Non Flooded |
| `weather/` | Weather classification | cloudy/overcast, foggy/hazy, rain/storm, snow/frosty, sun/clear |

> **Extending**: To add landslide, cyclone, earthquake, or other disaster models,
> update `MODELS` in `create_disaster_models.py` with the HuggingFace model ID
> and re-run the script.

---

## Folder Structure

```
flutter_models/
├── README.md
├── fire_smoke/
│   ├── fire_smoke_model.onnx
│   ├── fire_smoke_metadata.json
│   └── preprocessor_config.json
├── flood/
│   ├── flood_model.onnx
│   ├── flood_metadata.json
│   └── preprocessor_config.json
└── weather/
    ├── weather_model.onnx
    ├── weather_metadata.json
    └── preprocessor_config.json
```

---

## Flutter Integration

### 1. pubspec.yaml

```yaml
dependencies:
  onnxruntime: ^1.16.0
  image: ^4.1.0

flutter:
  assets:
    - assets/models/fire_smoke/
    - assets/models/flood/
    - assets/models/weather/
```

### 2. Preprocessing (matches SigLIP2 training)

All models expect:
- **Input shape**: `[1, 3, H, W]`  (batch, channels, height, width)
- **Pixel range**: `[-1, 1]`  (rescale by 1/255, subtract 0.5, divide by 0.5)
- **Channel order**: RGB

```dart
import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

Float32List preprocessImage(img.Image image, int height, int width) {
  final resized = img.copyResize(image, width: width, height: height);
  final buffer = Float32List(3 * height * width);

  for (var c = 0; c < 3; c++) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final pixel = resized.getPixel(x, y);
        final raw = c == 0 ? pixel.r : c == 1 ? pixel.g : pixel.b;
        // rescale → normalize: (raw/255 - 0.5) / 0.5
        buffer[c * height * width + y * width + x] =
            (raw.toDouble() / 255.0 - 0.5) / 0.5;
      }
    }
  }
  return buffer;
}
```

### 3. Inference helper

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

class DisasterDetector {
  late OrtSession _session;
  late Map<String, dynamic> _metadata;

  /// [modelAsset]    e.g. 'assets/models/fire_smoke/fire_smoke_model.onnx'
  /// [metaAsset]     e.g. 'assets/models/fire_smoke/fire_smoke_metadata.json'
  Future<void> load(String modelAsset, String metaAsset) async {
    OrtEnv.instance.init();

    final modelBytes = await rootBundle.load(modelAsset);
    _session = OrtSession.fromBuffer(
      modelBytes.buffer.asUint8List(),
      OrtSessionOptions(),
    );

    final metaStr = await rootBundle.loadString(metaAsset);
    _metadata = json.decode(metaStr) as Map<String, dynamic>;
  }

  Future<Map<String, double>> predict(Uint8List imageBytes) async {
    final decoded = img.decodeImage(imageBytes)!;
    final h = (_metadata['input_size'] as List)[0] as int;
    final w = (_metadata['input_size'] as List)[1] as int;

    final pixels = preprocessImage(decoded, h, w);

    final inputTensor = OrtValueTensor.createTensorWithDataList(
      pixels,
      [1, 3, h, w],
    );

    final outputs = await _session.runAsync(
      OrtRunOptions(),
      {'input': inputTensor},
    );

    final logits = (outputs[0]!.value as List<List<double>>)[0];
    final probs  = _softmax(logits);

    final id2label = _metadata['id2label'] as Map<String, dynamic>;
    return {
      for (var i = 0; i < probs.length; i++)
        id2label[i.toString()] as String: probs[i],
    };
  }

  List<double> _softmax(List<double> logits) {
    final maxVal = logits.reduce(max);
    final exps   = logits.map((x) => exp(x - maxVal)).toList();
    final sum    = exps.reduce((a, b) => a + b);
    return exps.map((x) => x / sum).toList();
  }

  void dispose() => _session.release();
}
```

### 4. Usage

```dart
final detector = DisasterDetector();
await detector.load(
  'assets/models/fire_smoke/fire_smoke_model.onnx',
  'assets/models/fire_smoke/fire_smoke_metadata.json',
);

final imageBytes = await File('photo.jpg').readAsBytes();
final results    = await detector.predict(imageBytes);

// Top prediction
final top = results.entries.reduce((a, b) => a.value > b.value ? a : b);
print('Detected: ${top.key} (${(top.value * 100).toStringAsFixed(1)}%)');
```

---

## Adding More Disaster Types

When fine-tuned models become available for landslide, cyclone, earthquake, etc.:

1. Add an entry to `MODELS` in `create_disaster_models.py`:
   ```python
   "landslide": {
       "hf_model": "some-org/landslide-detection-siglip2",
       "description": "Detects landslide vs normal terrain",
       "input_size": [224, 224],
       "source": "huggingface",
   },
   ```
2. Re-run: `python create_disaster_models.py`
3. Copy the new folder into your Flutter assets.

---

## Model Credits

- **fire_smoke**: [prithivMLmods/Fire-Detection-Siglip2](https://huggingface.co/prithivMLmods/Fire-Detection-Siglip2)
- **flood**: [prithivMLmods/Flood-Image-Detection](https://huggingface.co/prithivMLmods/Flood-Image-Detection)
- **weather**: [prithivMLmods/Weather-Image-Classification](https://huggingface.co/prithivMLmods/Weather-Image-Classification)

All models are based on Google's [SigLIP2](https://huggingface.co/google/siglip2-base-patch16-224) architecture.
