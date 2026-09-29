import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:shared_preferences/shared_preferences.dart';

/// What a log entry is for. Labels are English keys for tr().
enum LogKind {
  fuel(/*t*/'Fuel', Icons.local_gas_station_outlined),
  service(/*t*/'Service', Icons.build_outlined),
  repair(/*t*/'Repair', Icons.car_repair_outlined),
  toll(/*t*/'Toll', Icons.toll_outlined),
  parking(/*t*/'Parking', Icons.local_parking_outlined),
  wash(/*t*/'Wash', Icons.local_car_wash_outlined),
  insurance(/*t*/'Insurance', Icons.verified_user_outlined),
  other(/*t*/'Other', Icons.receipt_long_outlined);

  const LogKind(this.label, this.icon);
  final String label;
  final IconData icon;

  static LogKind parse(String s) => values.firstWhere((k) => k.name == s, orElse: () => other);
}

/// One fill-up, bill or service visit. Lives only on this phone.
class LogEntry {
  LogEntry({
    required this.id,
    required this.kind,
    required this.date,
    required this.amount,
    this.odometer,
    this.litres,
    this.fullTank = true,
    this.note,
    this.workshop,
  });

  final String id;
  final LogKind kind;
  final DateTime date;

  /// Rupees.
  final double amount;
  final int? odometer;

  /// Fuel only.
  final double? litres;

  /// Fuel only: whether the tank was filled to the brim, which mileage needs.
  final bool fullTank;
  final String? note;

  /// Service and repair only.
  final String? workshop;

  double? get pricePerLitre => litres == null || litres! <= 0 ? null : amount / litres!;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'date': date.toIso8601String(),
        'amount': amount,
        'odometer': odometer,
        'litres': litres,
        'fullTank': fullTank,
        'note': note,
        'workshop': workshop,
      };

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
        id: j['id'] as String,
        kind: LogKind.parse(j['kind'] as String),
        date: DateTime.parse(j['date'] as String),
        amount: (j['amount'] as num).toDouble(),
        odometer: (j['odometer'] as num?)?.toInt(),
        litres: (j['litres'] as num?)?.toDouble(),
        fullTank: j['fullTank'] as bool? ?? true,
        note: j['note'] as String?,
        workshop: j['workshop'] as String?,
      );
}

/// Mileage for one full-to-full stretch.
typedef MileagePoint = ({DateTime date, double kmpl, int km});

/// Full-to-full mileage: the km since the previous brim fill, divided by all
/// the fuel bought since then (including partial top-ups in between). A fill
/// without an odometer reading breaks the chain rather than guess.
List<MileagePoint> mileageSeries(Iterable<LogEntry> entries) {
  final fills = entries.where((e) => e.kind == LogKind.fuel && e.litres != null && e.litres! > 0).toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  final out = <MileagePoint>[];
  int? fromOdo;
  var litres = 0.0;
  for (final f in fills) {
    if (f.odometer == null) {
      fromOdo = null;
      litres = 0;
      continue;
    }
    if (fromOdo != null) litres += f.litres!;
    if (f.fullTank) {
      if (fromOdo != null && f.odometer! > fromOdo && litres > 0) {
        final km = f.odometer! - fromOdo;
        out.add((date: f.date, kmpl: km / litres, km: km));
      }
      fromOdo = f.odometer;
      litres = 0;
    }
  }
  return out;
}

/// Spend per calendar month, oldest first, for the last [months] months.
List<({DateTime month, double total})> monthlySpend(Iterable<LogEntry> entries, {int months = 6, DateTime? now}) {
  final n = now ?? DateTime.now();
  return [
    for (var i = months - 1; i >= 0; i--)
      (
        month: DateTime(n.year, n.month - i),
        total: entries
            .where((e) => e.date.year == DateTime(n.year, n.month - i).year && e.date.month == DateTime(n.year, n.month - i).month)
            .fold<double>(0, (s, e) => s + e.amount),
      ),
  ];
}

class GarageLog {
  static const _key = 'garage_log_v1';
  static final entries = ValueNotifier<List<LogEntry>>(const []);

  static Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return;
      entries.value = (jsonDecode(raw) as List).map((e) => LogEntry.fromJson(e as Map<String, dynamic>)).toList()..sort(_newestFirst);
    } catch (e) {
      debugPrint('garage log load failed: $e');
    }
  }

  static int _newestFirst(LogEntry a, LogEntry b) => b.date.compareTo(a.date);

  static Future<void> _save(List<LogEntry> list) async {
    list.sort(_newestFirst);
    entries.value = List.unmodifiable(list);
    await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  static Future<void> upsert(LogEntry e) => _save([...entries.value.where((x) => x.id != e.id), e]);

  static Future<void> remove(String id) => _save(entries.value.where((x) => x.id != id).toList());

  static String newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// Highest odometer reading logged, to prefill the next entry.
  static int? get lastOdometer =>
      entries.value.map((e) => e.odometer).whereType<int>().fold<int?>(null, (m, o) => m == null || o > m ? o : m);
}
