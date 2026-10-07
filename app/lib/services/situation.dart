import 'dart:io';

import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';

import 'damage_cost.dart';

enum Urgency { normal, high }

/// What the phone made of a photo: a reason for the alert, a drafted
/// message and how urgent it looks. A suggestion only; the person sends it.
class Situation {
  const Situation(this.kind, this.note, this.urgency);
  final String kind; // one of the scan function's KINDS
  final String note;
  final Urgency urgency;
}

// Substrings of ML Kit's image-label names. The base model has no "dented" or
// "blocked" class and labels every car photo with Vehicle, Car, Wheel, Road,
// Bumper, Windshield and so on, so those generic parts and surfaces are NOT
// evidence of anything (a real parked car came back with all of them and
// would have been called "blocking"). Only distinctive scene signs count;
// otherwise there is no suggestion and the person picks the reason.
const _rules = <(String kind, List<String> hints)>[
  ('accident', ['crash', 'collision', 'wreck', 'smash', 'shatter', 'debris', 'smoke']),
  ('towing', ['tow truck', 'recovery vehicle', 'flatbed']),
  ('blocking', ['gate', 'driveway', 'garage door']),
];

const _drafts = {
  'accident': /*t*/'There seems to be damage to your car. Please come when you can.',
  'towing': /*t*/'Your car looks like it\'s about to be towed. Please come right away.',
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


/// A report built from what the damage detector found in the photo, or null if it saw
/// nothing it is confident about. Only the four reliable classes count (the model saw
/// almost no broken lamps or flat tyres). The text is a draft the sender can change.
Situation? situationFromDamage(List<DamageFinding> found, {double minScore = 0.4, required String Function(DamageType) label, required String Function(String what) draft}) {
  const reliable = {DamageType.scratch, DamageType.dent, DamageType.crack, DamageType.glassShatter};
  final f = found.where((x) => x.score >= minScore && reliable.contains(x.type)).toList();
  if (f.isEmpty) return null;
  final counts = <DamageType, int>{};
  for (final x in f) {
    counts[x.type] = (counts[x.type] ?? 0) + 1;
  }
  final what = counts.entries.map((e) => e.value > 1 ? '${label(e.key).toLowerCase()} x${e.value}' : label(e.key).toLowerCase()).join(', ');
  final urgent = counts.containsKey(DamageType.glassShatter);
  return Situation('accident', draft(what), urgent ? Urgency.high : Urgency.normal);
}
