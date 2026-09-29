import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n.dart';
import '../main.dart';
import '../services/garage_log.dart';
import '../services/service_report.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';

enum LogFilter { all, fuel, service }

final _rupees = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);
String rupees(num v) => _rupees.format(v);

/// Fuel, expenses and service visits, kept on the phone. Mileage comes from
/// full-to-full fills; the service list exports as a PDF for resale.
class GarageLogScreen extends StatefulWidget {
  const GarageLogScreen({super.key, this.filter = LogFilter.all});
  final LogFilter filter;

  @override
  State<GarageLogScreen> createState() => _GarageLogScreenState();
}

class _GarageLogScreenState extends State<GarageLogScreen> {
  late LogFilter _filter = widget.filter;
  bool _exporting = false;

  bool _matches(LogEntry e) => switch (_filter) {
        LogFilter.all => true,
        LogFilter.fuel => e.kind == LogKind.fuel,
        LogFilter.service => e.kind == LogKind.service || e.kind == LogKind.repair,
      };

  Future<void> _exportPdf(List<LogEntry> all) async {
    final v = AppScope.read(context).vehicle!;
    setState(() => _exporting = true);
    try {
      final bytes = await ServiceReport.build(v, all);
      final name = 'service-history-${v.regNumber.toLowerCase()}.pdf';
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(bytes, mimeType: 'application/pdf', name: name)],
        fileNameOverrides: [name],
        subject: tr('Service history: {car}', {'car': '${v.make} ${v.model}'}),
      ));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<LogEntry>>(
      valueListenable: GarageLog.entries,
      builder: (context, all, _) {
        final shown = all.where(_matches).toList();
        final serviceCount = ServiceReport.visits(all).length;
        return Scaffold(
          appBar: AppBar(title: Text(_filter == LogFilter.service ? tr('Service history') : tr('Fuel and expenses'))),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => showLogEntrySheet(context, kind: _filter == LogFilter.service ? LogKind.service : LogKind.fuel),
            icon: const Icon(Icons.add),
            label: Text(tr('Add entry')),
          ),
          body: SafeArea(
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 104), children: [
              Reveal(child: _Summary(entries: all)),
              const SizedBox(height: 20),
              Reveal(
                index: 1,
                child: SegmentedButton<LogFilter>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: LogFilter.all, label: Text(tr('All'))),
                    ButtonSegment(value: LogFilter.fuel, label: Text(tr('Fuel'))),
                    ButtonSegment(value: LogFilter.service, label: Text(tr('Service'))),
                  ],
                  selected: {_filter},
                  onSelectionChanged: (s) => setState(() => _filter = s.first),
                ),
              ),
              const SizedBox(height: 16),
              Swap(
                child: _filter != LogFilter.service
                    ? const SizedBox(key: ValueKey('no-pdf'), width: double.infinity)
                    : Column(key: const ValueKey('pdf'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        OutlinedButton.icon(
                          icon: _exporting
                              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.picture_as_pdf_outlined),
                          label: Text(tr('Share service history (PDF)')),
                          onPressed: serviceCount == 0 || _exporting ? null : () => _exportPdf(all),
                        ),
                        const SizedBox(height: 8),
                        Text(tr('Buyers trust a car with a clear service record. The PDF is made on your phone.'), style: DLText.small),
                        const SizedBox(height: 16),
                      ]),
              ),
              Swap(
                child: shown.isEmpty
                    ? EmptyState(
                        key: ValueKey('empty-$_filter'),
                        icon: _filter == LogFilter.service ? Icons.build_outlined : Icons.local_gas_station_outlined,
                        title: _filter == LogFilter.service ? tr('No services logged') : tr('Nothing logged yet'),
                        body: _filter == LogFilter.service
                            ? tr('Add each service visit with the odometer reading. It builds a history you can share when you sell.')
                            : tr('Log fill-ups with the odometer reading and whether you filled the tank. Mileage appears after two full tanks.'),
                      )
                    : _EntryList(key: ValueKey('list-$_filter'), entries: shown),
              ),
              const SizedBox(height: 16),
              FootNote(tr('Your log stays on this phone. Connect never receives it.')),
            ]),
          ),
        );
      },
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.entries});
  final List<LogEntry> entries;

  @override
  Widget build(BuildContext context) {
    final months = monthlySpend(entries);
    final mileage = mileageSeries(entries);
    final latest = mileage.isEmpty ? null : mileage.last.kmpl;
    final litres = mileage.fold<double>(0, (s, m) => s + m.km / m.kmpl);
    final avg = mileage.isEmpty || litres == 0 ? null : mileage.fold<int>(0, (s, m) => s + m.km) / litres;
    return Column(children: [
      IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: SectionCard(
              padding: const EdgeInsets.fromLTRB(16, 16, 12, 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AnimatedFigure(rupees(months.last.total), style: DLText.numeral.copyWith(fontSize: 26)),
                const SizedBox(height: 8),
                Text(tr('Spent this month'), style: DLText.small),
              ]),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SectionCard(
              padding: const EdgeInsets.fromLTRB(16, 16, 12, 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text.rich(TextSpan(children: [
                  TextSpan(text: latest == null ? '—' : latest.toStringAsFixed(1), style: DLText.numeral.copyWith(fontSize: 26)),
                  if (latest != null) TextSpan(text: ' km/l', style: DLText.small),
                ])),
                const SizedBox(height: 8),
                Text(
                  avg == null ? tr('Mileage after two full tanks') : tr('Last fill · average {avg}', {'avg': avg.toStringAsFixed(1)}),
                  style: DLText.small,
                ),
              ]),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      SectionCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Label(tr('Last 6 months')),
          const SizedBox(height: 14),
          SizedBox(height: 96, child: _SpendBars(months: months)),
          if (mileage.length >= 2) ...[
            const SizedBox(height: 18),
            const Divider(),
            const SizedBox(height: 14),
            Label(tr('Mileage, km/l')),
            const SizedBox(height: 10),
            SizedBox(height: 56, width: double.infinity, child: _MileageLine(points: mileage.map((m) => m.kmpl).toList())),
          ],
        ]),
      ),
    ]);
  }
}

/// Monthly spend. The current month is ink, earlier months a quiet line
/// colour (violet stays reserved for things you can tap); bars grow in.
class _SpendBars extends StatelessWidget {
  const _SpendBars({required this.months});
  final List<({DateTime month, double total})> months;

  @override
  Widget build(BuildContext context) {
    final max = months.fold<double>(0, (m, x) => x.total > m ? x.total : m);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reduceMotion(context) ? 1 : 0, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: DL.ease,
      builder: (_, t, _) => Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (var i = 0; i < months.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(
            child: Column(children: [
              Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: max == 0 ? 0.03 : (months[i].total / max * t).clamp(0.03, 1.0),
                    child: Tooltip(
                      message: rupees(months[i].total),
                      child: Container(
                        decoration: BoxDecoration(
                          color: i == months.length - 1 ? DL.ink : DL.lineStrong,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(DateFormat.MMM().format(months[i].month), style: DLText.small.copyWith(fontSize: 11), maxLines: 1),
            ]),
          ),
        ],
      ]),
    );
  }
}

class _MileageLine extends StatelessWidget {
  const _MileageLine({required this.points});
  final List<double> points;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reduceMotion(context) ? 1 : 0, end: 1),
      duration: const Duration(milliseconds: 700),
      curve: DL.ease,
      builder: (_, t, _) => CustomPaint(painter: _LinePainter(points, t)),
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.points, this.t);
  final List<double> points;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final lo = points.reduce((a, b) => a < b ? a : b);
    final hi = points.reduce((a, b) => a > b ? a : b);
    final span = (hi - lo).abs() < 0.01 ? 1.0 : hi - lo;
    Offset at(int i) => Offset(
          i / (points.length - 1) * (size.width - 8) + 4,
          size.height - 4 - (points[i] - lo) / span * (size.height - 8),
        );
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * t),
      Paint()
        ..color = DL.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    if (t == 1) canvas.drawCircle(at(points.length - 1), 3.5, Paint()..color = DL.ink);
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.t != t || old.points != points;
}

class _EntryList extends StatelessWidget {
  const _EntryList({super.key, required this.entries});
  final List<LogEntry> entries;

  @override
  Widget build(BuildContext context) {
    final groups = <DateTime, List<LogEntry>>{};
    for (final e in entries) {
      groups.putIfAbsent(DateTime(e.date.year, e.date.month), () => []).add(e);
    }
    var i = 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final MapEntry(key: month, value: list) in groups.entries) ...[
        Reveal(
          index: i++,
          child: Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 10),
            child: Row(children: [
              Expanded(child: Label(DateFormat.yMMMM().format(month))),
              Text(rupees(list.fold<double>(0, (s, e) => s + e.amount)), style: DLText.small.copyWith(color: DL.ink)),
            ]),
          ),
        ),
        Reveal(
          index: i++,
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              for (var j = 0; j < list.length; j++) ...[if (j > 0) const Divider(), _EntryRow(entry: list[j])],
            ]),
          ),
        ),
        const SizedBox(height: 12),
      ],
    ]);
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry});
  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final details = [
      DateFormat.MMMd().format(e.date),
      if (e.kind == LogKind.fuel && e.litres != null) '${e.litres!.toStringAsFixed(1)} L${e.fullTank ? '' : ' · ${tr('top-up')}'}',
      if (e.pricePerLitre != null) '₹${e.pricePerLitre!.toStringAsFixed(1)}/L',
      if (e.odometer != null) '${NumberFormat.decimalPattern('en_IN').format(e.odometer)} km',
      if (e.workshop?.isNotEmpty == true) e.workshop!,
    ].join(' · ');
    return InkWell(
      onTap: () => showLogEntrySheet(context, existing: e),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(children: [
          IconBadge(e.kind.icon, size: 40),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.note?.isNotEmpty == true ? e.note! : tr(e.kind.label), style: DLText.strong, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(details, style: DLText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          const SizedBox(width: 8),
          Text(rupees(e.amount), style: DLText.strong.copyWith(fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

Future<void> showLogEntrySheet(BuildContext context, {LogEntry? existing, LogKind kind = LogKind.fuel}) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EntrySheet(existing: existing, kind: existing?.kind ?? kind),
    );

class _EntrySheet extends StatefulWidget {
  const _EntrySheet({this.existing, required this.kind});
  final LogEntry? existing;
  final LogKind kind;

  @override
  State<_EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends State<_EntrySheet> {
  final _form = GlobalKey<FormState>();
  late LogKind _kind = widget.kind;
  late DateTime _date = widget.existing?.date ?? DateUtils.dateOnly(DateTime.now());
  late final _amount = TextEditingController(text: widget.existing == null ? '' : widget.existing!.amount.toStringAsFixed(0));
  late final _odo = TextEditingController(text: widget.existing?.odometer?.toString() ?? '');
  late final _litres = TextEditingController(text: widget.existing?.litres?.toString() ?? '');
  late final _note = TextEditingController(text: widget.existing?.note ?? '');
  late final _workshop = TextEditingController(text: widget.existing?.workshop ?? '');
  late bool _full = widget.existing?.fullTank ?? true;

  @override
  void dispose() {
    for (final c in [_amount, _odo, _litres, _note, _workshop]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _isFuel => _kind == LogKind.fuel;
  bool get _isService => _kind == LogKind.service || _kind == LogKind.repair;

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    double? num(TextEditingController c) => double.tryParse(c.text.replaceAll(',', '').trim());
    await GarageLog.upsert(LogEntry(
      id: widget.existing?.id ?? GarageLog.newId(),
      kind: _kind,
      date: _date,
      amount: num(_amount)!,
      odometer: num(_odo)?.round(),
      litres: _isFuel ? num(_litres) : null,
      fullTank: _isFuel ? _full : true,
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      workshop: _isService && _workshop.text.trim().isNotEmpty ? _workshop.text.trim() : null,
    ));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final digits = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    final lastOdo = GarageLog.lastOdometer;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.existing == null ? tr('Add entry') : tr('Edit entry'), style: DLText.title),
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final k in LogKind.values)
                ChoiceChip(
                  avatar: Icon(k.icon, size: 18),
                  label: Text(tr(k.label)),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ]),
            const SizedBox(height: 20),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  FieldLabel(tr('Amount')),
                  TextFormField(
                    controller: _amount,
                    autofocus: widget.existing == null,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: digits,
                    decoration: const InputDecoration(prefixText: '₹ ', hintText: '2500'),
                    validator: (v) => (double.tryParse((v ?? '').replaceAll(',', '')) ?? 0) > 0 ? null : tr('Enter the amount'),
                  ),
                ]),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  FieldLabel(tr('Date')),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12), minimumSize: const Size(44, 50)),
                    onPressed: () async {
                      final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2000), lastDate: DateTime.now());
                      if (d != null) setState(() => _date = d);
                    },
                    child: Text(DateFormat.yMMMd().format(_date)),
                  ),
                ]),
              ),
            ]),
            const SizedBox(height: 16),
            FieldLabel(tr('Odometer (optional)')),
            TextFormField(
              controller: _odo,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(suffixText: 'km', hintText: lastOdo == null ? '12500' : '$lastOdo'),
              validator: (v) => _isFuel && _litres.text.isNotEmpty && (v ?? '').isEmpty && _full ? tr('Mileage needs the odometer reading') : null,
            ),
            Swap(
              child: _isFuel
                  ? Column(key: const ValueKey('fuel'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const SizedBox(height: 16),
                      FieldLabel(tr('Litres')),
                      TextFormField(
                        controller: _litres,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: digits,
                        decoration: const InputDecoration(suffixText: 'L', hintText: '25.4'),
                      ),
                      const SizedBox(height: 4),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _full,
                        onChanged: (v) => setState(() => _full = v ?? true),
                        title: Text(tr('Filled the tank to full')),
                        subtitle: Text(tr('Mileage is measured between full tanks')),
                      ),
                    ])
                  : _isService
                      ? Column(key: const ValueKey('service'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          const SizedBox(height: 16),
                          FieldLabel(tr('Workshop (optional)')),
                          TextFormField(
                            controller: _workshop,
                            textCapitalization: TextCapitalization.words,
                            decoration: InputDecoration(hintText: tr('e.g. Maruti Arena, Indiranagar')),
                          ),
                        ])
                      : const SizedBox(key: ValueKey('none'), width: double.infinity),
            ),
            const SizedBox(height: 16),
            FieldLabel(_isService ? tr('Work done') : tr('Note (optional)')),
            TextFormField(
              controller: _note,
              maxLength: 80,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(hintText: _isService ? tr('e.g. Oil change, brake pads') : tr('e.g. Highway trip')),
            ),
            const SizedBox(height: 8),
            FilledButton(onPressed: _save, child: Text(tr('Save'))),
            if (widget.existing != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: DL.error, iconColor: DL.error),
                icon: const Icon(Icons.delete_outline),
                label: Text(tr('Delete entry')),
                onPressed: () async {
                  await GarageLog.remove(widget.existing!.id);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
