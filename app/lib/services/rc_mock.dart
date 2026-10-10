/// What an RC (Registration Certificate) lookup returns for a plate.
///
/// DEMO DATA: until a Surepass token is set on the server, the app builds a
/// realistic record from the plate itself. The same plate always gives the
/// same car, so a demo is repeatable. Swap [RcRecord.fromJson] in once the
/// `rc-lookup` edge function answers with real data (it never sends the owner).
class RcRecord {
  const RcRecord({
    required this.plate, required this.make, required this.model, required this.fuel,
    required this.colour, required this.registered, required this.insuranceUpto,
    required this.fitnessUpto, required this.pucUpto, required this.rto,
    required this.chassisLast4, required this.engineLast4, required this.norms,
    required this.ownerMasked, required this.financed, this.mock = true,
  });

  final String plate, make, model, fuel, colour, rto, chassisLast4, engineLast4, norms, ownerMasked;
  final DateTime registered, insuranceUpto, fitnessUpto, pucUpto;
  final bool financed, mock;

  bool get insured => insuranceUpto.isAfter(DateTime.now());
  bool get pucValid => pucUpto.isAfter(DateTime.now());

  /// Server shape from `rc-lookup`. The server never sends the owner or the
  /// chassis/engine tail, so those are filled from the demo generator.
  factory RcRecord.fromServer(String plate, Map<String, dynamic> v) {
    final base = RcRecord.demo(plate);
    DateTime? d(Object? s) => s == null ? null : DateTime.tryParse('$s');
    return RcRecord(
      plate: plate,
      make: (v['make'] as String?) ?? base.make,
      model: (v['model'] as String?) ?? base.model,
      fuel: (v['fuel'] as String?) ?? base.fuel,
      colour: (v['color'] as String?) ?? base.colour,
      registered: d(v['registered']) ?? base.registered,
      insuranceUpto: d(v['insurance_upto']) ?? base.insuranceUpto,
      fitnessUpto: d(v['fitness_upto']) ?? base.fitnessUpto,
      pucUpto: base.pucUpto,
      rto: base.rto,
      chassisLast4: base.chassisLast4,
      engineLast4: base.engineLast4,
      norms: base.norms,
      ownerMasked: base.ownerMasked,
      financed: base.financed,
      mock: v['mock'] == true,
    );
  }

  factory RcRecord.demo(String plate) {
    final h = _hash(plate);
    final c = _cars[h % _cars.length];
    final yearsOld = 1 + (h ~/ 7) % 6;
    final reg = DateTime.now().subtract(Duration(days: 365 * yearsOld + (h ~/ 11) % 300));
    final insLeft = 40 + (h ~/ 13) % 300;
    return RcRecord(
      plate: plate,
      make: c.make,
      model: c.model,
      fuel: c.fuel,
      colour: _colours[(h ~/ 3) % _colours.length],
      registered: reg,
      insuranceUpto: DateTime.now().add(Duration(days: insLeft)),
      fitnessUpto: reg.add(const Duration(days: 365 * 15)),
      pucUpto: DateTime.now().add(Duration(days: 20 + (h ~/ 17) % 160)),
      rto: _rto(plate),
      chassisLast4: _digits(h, 4),
      engineLast4: _digits(h ~/ 5, 4),
      norms: reg.year >= 2023 ? 'BS-VI Phase 2' : 'BS-VI',
      ownerMasked: _owners[h % _owners.length],
      financed: h % 4 == 0,
    );
  }

  /// A demo record bent to look like the car the app has actually seen: what
  /// the car photo showed first, then what the RC photo said. Anything not
  /// given keeps its made-up value. The registration number never changes, so
  /// the plate check stays honest.
  RcRecord adaptedTo({
    String? make, String? model, String? fuel, String? colour, String? owner,
    String? chassis, String? engine, String? registered,
  }) {
    String? tail(String? v) {
      final t = v?.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
      return t == null || t.length < 4 ? null : t.substring(t.length - 4);
    }

    String masked(String name) => name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w.length <= 2 ? w : w.substring(0, 2) + '*' * (w.length - 2).clamp(1, 6))
        .join(' ');

    String? title(String? v) => v == null || v.isEmpty ? null : v[0].toUpperCase() + v.substring(1).toLowerCase();
    final reg = DateTime.tryParse(registered ?? '') ?? this.registered;
    return RcRecord(
      plate: plate,
      make: make ?? this.make,
      model: model ?? this.model,
      fuel: title(fuel) ?? this.fuel,
      colour: title(colour) ?? this.colour,
      registered: reg,
      insuranceUpto: insuranceUpto,
      fitnessUpto: reg.add(const Duration(days: 365 * 15)),
      pucUpto: pucUpto,
      rto: rto,
      chassisLast4: tail(chassis) ?? chassisLast4,
      engineLast4: tail(engine) ?? engineLast4,
      norms: reg.year >= 2023 ? 'BS-VI Phase 2' : 'BS-VI',
      ownerMasked: owner == null || owner.trim().isEmpty ? ownerMasked : masked(owner),
      financed: financed,
      mock: mock,
    );
  }

  /// The owner's name as printed on the RC, for the demo match.
  String get ownerOnRc => ownerMasked.replaceAll('*', '').trim();

  static int _hash(String s) {
    var h = 17;
    for (final u in s.codeUnits) {
      h = (h * 31 + u) & 0x7fffffff;
    }
    return h;
  }

  static String _digits(int h, int n) => (h % 10000).toString().padLeft(n, '0');

  static String _rto(String plate) {
    const states = {
      'KA': 'Karnataka', 'MH': 'Maharashtra', 'DL': 'Delhi', 'TN': 'Tamil Nadu',
      'TS': 'Telangana', 'AP': 'Andhra Pradesh', 'KL': 'Kerala', 'GJ': 'Gujarat',
      'UP': 'Uttar Pradesh', 'RJ': 'Rajasthan', 'WB': 'West Bengal', 'HR': 'Haryana',
    };
    final st = plate.length >= 2 ? plate.substring(0, 2) : '';
    final code = RegExp(r'^[A-Z]{2}(\d{1,2})').firstMatch(plate)?.group(1) ?? '';
    return '${states[st] ?? st} · RTO $st-${code.padLeft(2, '0')}';
  }

  static const _colours = ['White', 'Silver', 'Grey', 'Black', 'Red', 'Blue'];
  static const _owners = ['Ra*** K*****', 'Su*** N***', 'An*** S****', 'Pr*** R**', 'Vi*** M*****', 'De*** A****'];
  static const _cars = <({String make, String model, String fuel})>[
    (make: 'Maruti Suzuki', model: 'Swift VXi', fuel: 'Petrol'),
    (make: 'Hyundai', model: 'Creta SX', fuel: 'Diesel'),
    (make: 'Tata', model: 'Nexon XZ+', fuel: 'Petrol'),
    (make: 'Honda', model: 'City ZX', fuel: 'Petrol'),
    (make: 'Mahindra', model: 'XUV700 AX5', fuel: 'Diesel'),
    (make: 'Toyota', model: 'Innova Crysta', fuel: 'Diesel'),
    (make: 'Kia', model: 'Seltos HTX', fuel: 'Petrol'),
    (make: 'Maruti Suzuki', model: 'Baleno Delta', fuel: 'Petrol'),
  ];
}
