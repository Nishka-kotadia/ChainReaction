import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'models.dart';

// ============================================================
// ResQMesh — Edge AI Triage Service
// Fully offline, deterministic NLP rules-engine.
// Executes in < 1ms on device CPU. No internet required.
// ============================================================

/// Structured output from the Edge AI Triage engine.
class TriageResult {
  final SeverityScore severity;
  final AlertType alertType;
  final String action;

  const TriageResult({
    required this.severity,
    required this.alertType,
    required this.action,
  });
}

/// Internal structure binding a keyword to its triage rule.
class _TriageRule {
  final SeverityScore severity;
  final AlertType alertType;
  final String action;

  const _TriageRule(this.severity, this.alertType, this.action);
}

/// The AI triage engine.
/// Call [evaluateEmergency] with a raw description string.
class AITriageService {

  // ── Rules Table ───────────────────────────────────────────
  // Ordered from highest to lowest severity.
  // On a keyword match, the highest-severity rule wins.
  static const Map<String, _TriageRule> _rules = {
    // CRITICAL
    'unconscious':    _TriageRule(SeverityScore.critical, AlertType.injury,     'Dispatch immediate medical rescue. Check airway. Begin CPR if no pulse.'),
    'not breathing':  _TriageRule(SeverityScore.critical, AlertType.injury,     'Perform CPR immediately. Dispatch emergency responders at once.'),
    'cardiac':        _TriageRule(SeverityScore.critical, AlertType.injury,     'Use AED if available. Begin CPR. Dispatch emergency medical services.'),
    'heart attack':   _TriageRule(SeverityScore.critical, AlertType.injury,     'Call medical team immediately. Keep patient still and calm. Do not give food/water.'),
    'severe bleeding':_TriageRule(SeverityScore.critical, AlertType.injury,     'Apply tourniquet or direct pressure immediately. Elevate limb if possible.'),
    'drowning':       _TriageRule(SeverityScore.critical, AlertType.injury,     'Remove from water immediately. Begin CPR. Keep warm. Dispatch medics.'),
    'collapsed':      _TriageRule(SeverityScore.critical, AlertType.injury,     'Check responsiveness. Begin CPR if unresponsive. Dispatch medics.'),

    // HIGH
    'fire':           _TriageRule(SeverityScore.high,     AlertType.fire,       'Evacuate area. Stay low. Use extinguisher only if safe. Dispatch fire brigade.'),
    'smoke':          _TriageRule(SeverityScore.high,     AlertType.fire,       'Evacuate immediately. Stay low to avoid smoke. Dispatch fire brigade.'),
    'explosion':      _TriageRule(SeverityScore.high,     AlertType.fire,       'Evacuate all personnel immediately. Do not use elevators. Dispatch emergency services.'),
    'trapped':        _TriageRule(SeverityScore.high,     AlertType.trapped,    'Deploy search and rescue extraction team. Do not move unstable debris.'),
    'buried':         _TriageRule(SeverityScore.high,     AlertType.trapped,    'Mark location. Send rescue team with extraction equipment.'),
    'flood':          _TriageRule(SeverityScore.high,     AlertType.flood,      'Move to elevated ground immediately. Avoid walking in flowing water.'),
    'rising water':   _TriageRule(SeverityScore.high,     AlertType.flood,      'Evacuate to higher ground. Deploy water rescue team.'),
    'earthquake':     _TriageRule(SeverityScore.high,     AlertType.earthquake, 'Drop, cover, hold on. After shaking stops, evacuate carefully. Watch for aftershocks.'),
    'bleeding':       _TriageRule(SeverityScore.high,     AlertType.injury,     'Apply direct pressure to wound. Elevate if possible. Dispatch medics.'),

    // MEDIUM
    'fracture':       _TriageRule(SeverityScore.medium,   AlertType.injury,     'Immobilize the area. Do not attempt to realign. Apply ice if available. Await medics.'),
    'broken bone':    _TriageRule(SeverityScore.medium,   AlertType.injury,     'Immobilize the limb. Do not attempt to straighten. Wait for medical transport.'),
    'burn':           _TriageRule(SeverityScore.medium,   AlertType.injury,     'Cool burn with running water for 10 minutes. Cover loosely with sterile dressing.'),
    'head injury':    _TriageRule(SeverityScore.medium,   AlertType.injury,     'Keep patient still. Do not remove helmet if present. Monitor consciousness.'),
    'missing':        _TriageRule(SeverityScore.medium,   AlertType.missing,    'Broadcast last known location. Deploy search teams. Alert all mesh nodes.'),
    'landslide':      _TriageRule(SeverityScore.medium,   AlertType.earthquake, 'Evacuate slope areas. Watch for further movement. Dispatch rescue.'),

    // LOW
    'cut':            _TriageRule(SeverityScore.low,      AlertType.injury,     'Clean wound thoroughly with water. Apply bandage. Monitor for infection.'),
    'sprain':         _TriageRule(SeverityScore.low,      AlertType.injury,     'Rest, Ice, Compression, Elevation (RICE). Avoid using affected limb.'),
    'lost':           _TriageRule(SeverityScore.low,      AlertType.missing,    'Stay in place. Broadcast your GPS coordinates. Await rescue team.'),
    'stranded':       _TriageRule(SeverityScore.low,      AlertType.missing,    'Stay with vehicle or shelter. Broadcast location. Conserve phone battery.'),
    'dehydrated':     _TriageRule(SeverityScore.low,      AlertType.injury,     'Provide water immediately. Move to shade. Monitor condition.'),
  };

  /// Evaluates a raw emergency description string and returns a structured [TriageResult].
  ///
  /// The engine scans all keywords against the description (case-insensitive)
  /// and returns the highest-severity match found.
  static TriageResult evaluateEmergency(String description) {
    final String lower = description.toLowerCase();

    SeverityScore highestSeverity = SeverityScore.low;
    AlertType detectedType = AlertType.general;
    String primaryAction = 'Monitor the situation. Broadcast to mesh. Await further updates.';

    for (final MapEntry<String, _TriageRule> entry in _rules.entries) {
      if (lower.contains(entry.key)) {
        final _TriageRule rule = entry.value;

        // Upgrade if this rule has higher severity than current best match
        if (rule.severity.index > highestSeverity.index) {
          highestSeverity = rule.severity;
          detectedType = rule.alertType;
          primaryAction = rule.action;
        }
      }
    }

    return TriageResult(
      severity: highestSeverity,
      alertType: detectedType,
      action: primaryAction,
    );
  }
}

// ============================================================
// ResQMesh — Edge Image Detection
// Fully offline using Google ML Kit Image Labeling.
// Extracts tags (like "Fire", "Flood", "Person") from photos.
// ============================================================
class OfflineImageScanner {
  static final ImageLabeler _labeler = ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.6));

  /// Scans the image at [imagePath] and returns a comma-separated list of detected labels.
  /// Example return: "Fire, Smoke, Building, Vehicle"
  static Future<String> scanEmergencyImage(String imagePath) async {
    try {
      debugPrint('📷 ResQMesh: Scanning image offline for emergency objects...');
      final inputImage = InputImage.fromFilePath(imagePath);
      final List<ImageLabel> labels = await _labeler.processImage(inputImage);
      
      if (labels.isEmpty) return "";

      // Extract the text of the labels
      final detectedTags = labels.map((e) => e.label).toList();
      debugPrint('📷 ResQMesh: Detected labels -> ${detectedTags.join(", ")}');
      
      return detectedTags.join(", ");
    } catch (e) {
      debugPrint('❌ ResQMesh: Offline image scan failed: $e');
      return "";
    }
  }

  static void dispose() {
    _labeler.close();
  }
}
