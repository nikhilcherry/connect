import 'dart:io';

import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';

enum Urgency { normal, high }

/// What the phone made of a photo: a reason for the alert, a drafted
/// message and how urgent it looks. A suggestion only; the person sends it.
class Situation {
  const Situation(this.kind, this.note, this.urgency);
  final String kind; // one of the scan function's KINDS
  final String note;
  final Urgency urgency;
}

// Substrings of ML Kit's image-label names, strongest signal first. The base
// model has no "dented" or "blocked" class, so this reads the scene: what is
// in the frame says what the problem most likely is.
const _rules = <(String kind, List<String> hints)>[
  ('accident', ['crash', 'collision', 'bumper', 'dent', 'broken', 'wreck', 'smash', 'shatter', 'debris']),
  ('towing', ['tow', 'crane', 'recovery', 'flatbed']),
  ('lights_on', ['headlamp', 'headlight', 'automotive lighting', 'taillight', 'light']),
  ('window_open', ['window', 'windshield', 'vehicle door', 'door', 'sunroof']),
  ('blocking', ['gate', 'driveway', 'parking', 'garage', 'road', 'asphalt', 'street', 'fence', 'wall']),
];

const _drafts = {
  'accident': /*t*/'There seems to be damage to your car. Please come when you can.',
  'towing': /*t*/'Your car looks like it\'s about to be towed. Please come right away.',
  'lights_on': /*t*/'Your car\'s lights are on.',
  'window_open': /*t*/'A window or door on your car looks open.',
  'blocking': /*t*/'Your car is blocking the way. Could you move it?',
  'other': '',
};

/// Pure, so it is testable without a camera. [labels] maps label text to
/// confidence (0..1).
Situation? interpretLabels(Map<String, double> labels) {
  final strong = {for (final e in labels.entries) if (e.value >= 0.55) e.key.toLowerCase(): e.value};
  if (strong.isEmpty) return null;
  // Rank by the best-scoring label that hits a rule; rule order breaks ties.
  String? best;
  var bestScore = 0.0;
  for (final (kind, hints) in _rules) {
    for (final e in strong.entries) {
      if (hints.any(e.key.contains) && e.value > bestScore + 0.04) {
        best = kind;
        bestScore = e.value;
      }
    }
  }
  if (best == null) return null;
  return Situation(best, _drafts[best]!, best == 'accident' || best == 'towing' ? Urgency.high : Urgency.normal);
}

/// On-device image labelling (ML Kit base model). The photo stays on the phone.
Future<Situation?> readSituation(File photo) async {
  final labeler = ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.5));
  try {
    final labels = await labeler.processImage(InputImage.fromFile(photo));
    return interpretLabels({for (final l in labels) l.label: l.confidence});
  } finally {
    await labeler.close();
  }
}
