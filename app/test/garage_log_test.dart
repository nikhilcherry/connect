import 'package:connect/data/models.dart';
import 'package:connect/services/garage_log.dart';
import 'package:connect/services/service_report.dart';
import 'package:flutter_test/flutter_test.dart';

LogEntry fill(int day, {int? odo, double litres = 30, bool full = true, double amount = 3000}) => LogEntry(
      id: '$day',
      kind: LogKind.fuel,
      date: DateTime(2026, 9, day),
      amount: amount,
      odometer: odo,
      litres: litres,
      fullTank: full,
    );

void main() {
  test('mileage is km between full tanks over the fuel bought since', () {
    final m = mileageSeries([fill(1, odo: 10000), fill(8, odo: 10450, litres: 30)]);
    expect(m, hasLength(1));
    expect(m.single.km, 450);
    expect(m.single.kmpl, closeTo(15, 0.001));
  });

  test('partial top-ups count toward the next full tank', () {
    final m = mileageSeries([
      fill(1, odo: 10000),
      fill(4, odo: 10200, litres: 10, full: false),
      fill(8, odo: 10600, litres: 30),
    ]);
    expect(m.single.km, 600);
    expect(m.single.kmpl, closeTo(15, 0.001));
  });

  test('the first full tank only starts the chain', () {
    expect(mileageSeries([fill(1, odo: 10000)]), isEmpty);
  });

  test('a fill without an odometer reading breaks the chain instead of guessing', () {
    final m = mileageSeries([fill(1, odo: 10000), fill(4), fill(8, odo: 10450), fill(15, odo: 10900)]);
    expect(m.single.km, 450);
  });

  test('entries are sorted by date before measuring', () {
    final m = mileageSeries([fill(8, odo: 10450), fill(1, odo: 10000)]);
    expect(m.single.km, 450);
  });

  test('monthly spend covers the last six months, oldest first, with empty months as zero', () {
    final entries = [
      fill(1, amount: 1000),
      LogEntry(id: 'x', kind: LogKind.toll, date: DateTime(2026, 7, 10), amount: 250),
    ];
    final months = monthlySpend(entries, now: DateTime(2026, 9, 24));
    expect(months.map((m) => m.month.month), [4, 5, 6, 7, 8, 9]);
    expect(months.map((m) => m.total), [0, 0, 0, 250, 0, 1000]);
  });

  test('entries round-trip through JSON', () {
    final e = fill(3, odo: 12345, full: false);
    final back = LogEntry.fromJson(e.toJson());
    expect(back.odometer, 12345);
    expect(back.fullTank, isFalse);
    expect(back.kind, LogKind.fuel);
    expect(back.pricePerLitre, closeTo(100, 0.001));
  });

  test('service history builds a PDF from service and repair visits only', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final v = Vehicle(id: 'v', owner: 'o', regNumber: 'KA05MN4821', make: 'Hyundai', model: 'Creta');
    final entries = [
      fill(1, odo: 10000),
      LogEntry(id: 's', kind: LogKind.service, date: DateTime(2026, 8, 20), amount: 5400, odometer: 11200, note: 'Oil change', workshop: 'Blue Hands'),
      LogEntry(id: 'r', kind: LogKind.repair, date: DateTime(2026, 9, 2), amount: 1200, note: 'Wiper motor'),
    ];
    expect(ServiceReport.visits(entries).map((e) => e.id), ['s', 'r']);
    final pdf = await ServiceReport.build(v, entries);
    expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    expect(pdf.length, greaterThan(2000));
  });
}
