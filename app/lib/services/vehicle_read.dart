import '../data/car_catalog.dart';
import 'rc_check.dart';
import 'rc_mock.dart';

/// What the local vision model read off the owner's car photo. Every field is
/// null when the model could not see it; nothing is guessed.
class CarRead {
  const CarRead({required this.plate, this.make, this.model, this.colour, this.bodyType, this.fuel, this.features, this.condition});

  /// Always set: from the on-device plate reader, or typed when that fails.
  final String plate;
  final String? make, model, colour, bodyType, fuel, features, condition;

  /// Extra facts kept on the vehicle row beside the columns it already has.
  Map<String, dynamic> toDetails() => {
        if (bodyType != null) 'body_type': bodyType,
        if (fuel != null) 'fuel': fuel,
        if (features != null) 'features': features,
        if (condition != null) 'condition': condition,
      };
}

/// The colour in the app's own list (stored in English), or null.
String? canonicalColour(String? raw) {
  if (raw == null) return null;
  final s = raw.toLowerCase();
  const map = {
    'white': 'White', 'silver': 'Silver', 'grey': 'Grey', 'gray': 'Grey', 'graphite': 'Grey', 'black': 'Black',
    'red': 'Red', 'maroon': 'Red', 'blue': 'Blue', 'brown': 'Brown', 'bronze': 'Brown', 'beige': 'Brown',
    'green': 'Green', 'orange': 'Orange', 'yellow': 'Yellow', 'gold': 'Yellow',
  };
  for (final e in map.entries) {
    if (s.contains(e.key)) return e.value;
  }
  return null;
}

/// The catalog entry for a make and model read off a photo or an RC, if any.
CarSpec? catalogMatch(String? make, String? model) {
  if (make == null || model == null) return null;
  for (final c in carCatalog) {
    if (sameMaker(c.make, make) && sameModel(c.model, model)) return c;
  }
  return null;
}

const _noise = {'india', 'ltd', 'limited', 'motors', 'motor', 'private', 'pvt', 'company', 'corporation', 'cars', 'car', 'and', 'the'};

Set<String> _words(String s, {bool dropNoise = true}) => RegExp(r'[a-z0-9]+')
    .allMatches(s.toLowerCase())
    .map((m) => m[0]!)
    .where((w) => w.length >= 2 && !(dropNoise && _noise.contains(w)))
    .toSet();

/// "MARUTI SUZUKI INDIA LTD" and "Maruti Suzuki" are the same maker.
bool sameMaker(String a, String b) {
  final x = _words(a), y = _words(b);
  return x.any((w) => y.contains(w) || y.any((v) => v.length >= 4 && w.length >= 4 && (v.startsWith(w) || w.startsWith(v))));
}

/// "SWIFT VXI" and "Swift" are the same model: the leading word decides.
bool sameModel(String a, String b) {
  final x = RegExp(r'[a-z0-9]+').firstMatch(a.toLowerCase())?[0];
  final y = RegExp(r'[a-z0-9]+').firstMatch(b.toLowerCase())?[0];
  if (x == null || y == null) return false;
  return x == y || _words(a, dropNoise: false).intersection(_words(b, dropNoise: false)).isNotEmpty;
}

enum CheckState { pass, warn, skip, fail }

class RcCheck {
  const RcCheck(this.label, this.state, [this.detail]);
  final String label; // an English key for tr()
  final CheckState state;
  final String? detail;
}

/// What the RC photo, the RC lookup and the car photo say, side by side.
class RcResult {
  const RcResult({required this.rc, required this.read, required this.checks, required this.usedModel});
  final RcRecord rc;
  final Map<String, String?> read;
  final List<RcCheck> checks;
  final bool usedModel;

  bool get accepted => !checks.any((c) => c.state == CheckState.fail);

  Map<String, dynamic> toDetails() => {
        'rc_verified': true,
        'rc_verified_at': DateTime.now().toUtc().toIso8601String(),
        'rc_read_by_model': usedModel,
        'rc_lookup_demo': rc.mock,
        if (read['fuel'] != null) 'fuel': read['fuel'],
        if (read['colour'] != null) 'rc_colour': read['colour'],
        if (read['registered'] != null) 'registered': read['registered'],
        if (read['valid_upto'] != null) 'rc_valid_upto': read['valid_upto'],
        if (_tail(read['chassis']) != null) 'chassis_last4': _tail(read['chassis']),
        if (_tail(read['engine']) != null) 'engine_last4': _tail(read['engine']),
      };
}

String? _tail(String? s) {
  final t = s?.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  return t == null || t.length < 4 ? null : t.substring(t.length - 4);
}

/// The first two letters of each word, the way the lookup masks a name.
bool _ownerMatches(String onRc, String masked) {
  final a = onRc.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final b = masked.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (a.isEmpty || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final keep = b[i].replaceAll('*', '');
    if (keep.isEmpty || !a[i].startsWith(keep)) return false;
  }
  return true;
}

/// Compares the RC the owner photographed with the RC lookup. Against demo
/// data nothing can fail (any RC is accepted for now; a mismatch only warns);
/// against a real record a wrong registration number, maker, chassis or owner does.
List<RcCheck> compareRc({required String plate, required RcRecord lookup, required Map<String, String?> read, CarRead? car}) {
  final demo = lookup.mock;
  RcCheck vs(String label, bool? same, String shown, {bool hard = false}) {
    if (same == null) return RcCheck(label, CheckState.skip);
    if (same) return RcCheck(label, CheckState.pass, shown);
    return RcCheck(label, demo ? CheckState.skip : (hard ? CheckState.fail : CheckState.warn), shown);
  }

  final rcPlate = read['plate'];
  final regOk = rcPlate != null && rcTextMatchesPlate(rcPlate, plate);
  final chassis = _tail(read['chassis']);
  final checks = <RcCheck>[
    RcCheck(/*t*/'Registration number matches', regOk ? CheckState.pass : (demo ? CheckState.warn : CheckState.fail), rcPlate),
    vs(/*t*/'Maker matches the RC lookup', read['make'] == null ? null : sameMaker(read['make']!, lookup.make), '${read['make']}', hard: true),
    vs(/*t*/'Model matches the RC lookup', read['model'] == null ? null : sameModel(read['model']!, lookup.model), '${read['model']}'),
    vs(/*t*/'Fuel matches the RC lookup', read['fuel']?.toLowerCase().contains(lookup.fuel.toLowerCase().substring(0, 3)), '${read['fuel']}'),
    vs(/*t*/'Chassis number matches', chassis == null ? null : chassis == lookup.chassisLast4, '…$chassis', hard: true),
    vs(/*t*/'Owner name matches the RC lookup', read['owner'] == null ? null : _ownerMatches(read['owner']!, lookup.ownerMasked), '${read['owner']}', hard: true),
  ];
  if (car?.make != null && read['make'] != null) {
    final same = sameMaker(car!.make!, read['make']!);
    checks.add(RcCheck(/*t*/'Car in your photo matches the RC', same ? CheckState.pass : CheckState.warn));
  }
  final upto = DateTime.tryParse(read['valid_upto'] ?? '');
  if (upto != null) {
    checks.add(RcCheck(/*t*/'RC is still valid', upto.isAfter(DateTime.now()) ? CheckState.pass : CheckState.warn, read['valid_upto']));
  }
  return checks;
}
