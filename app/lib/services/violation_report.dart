import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'roadguard.dart';

/// Why a violation cannot be reported right now (or [none] if it can).
enum ReportBlock {
  none,

  /// No webhook is configured in this build, so reporting is not offered at all.
  notConfigured,

  /// Potholes are not traffic violations.
  notAViolation,

  /// The number plate is missing or could not be read as a valid plate. A report without a clear
  /// plate identifies nobody, so it is never sent.
  plateNotClear,

  /// No GPS fix was recorded for this event, so there is no latitude and longitude to send.
  noLocation,

  alreadyReported,
}

/// What came back from a send attempt.
class ReportResult {
  const ReportResult(this.ok, [this.detail = '']);

  final bool ok;
  final String detail;
}

/// Sends an authorised violation to the reporting webhook: the photo, the plate, the time and the
/// latitude and longitude. Only the person who authorises a report triggers a send; nothing here
/// runs on its own.
class ViolationReporter {
  ViolationReporter({String? url, this.timeout = const Duration(seconds: 25)})
      : url = (url ?? Config.violationWebhookUrl).isEmpty ? null : Uri.parse(url ?? Config.violationWebhookUrl);

  /// Where reports go, or null if this build has none configured.
  final Uri? url;
  final Duration timeout;

  static const _prefReported = 'reported_violations';

  bool get configured => url != null;

  /// The rule for "may this be reported". Pure, so it can be tested without a network or a phone.
  static ReportBlock check(RoadEvent e, {required bool configured, bool alreadyReported = false}) {
    if (!configured) return ReportBlock.notConfigured;
    if (!e.isViolation) return ReportBlock.notAViolation;
    if (alreadyReported) return ReportBlock.alreadyReported;
    if (!e.plateClear) return ReportBlock.plateNotClear;
    if (!e.hasLocation) return ReportBlock.noLocation;
    return ReportBlock.none;
  }

  Future<Set<String>> reportedIds() async {
    try {
      final p = await SharedPreferences.getInstance();
      return (p.getStringList(_prefReported) ?? const <String>[]).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> _markReported(String id) async {
    try {
      final p = await SharedPreferences.getInstance();
      final all = (p.getStringList(_prefReported) ?? <String>[])..add(id);
      await p.setStringList(_prefReported, all.toSet().toList());
    } catch (_) {}
  }

  /// Builds the multipart body: text fields, then the photo and the plate crop as files.
  @visibleForTesting
  static List<int> buildBody(String boundary, Map<String, String> fields, Map<String, List<int>> files) {
    final b = BytesBuilder();
    for (final f in fields.entries) {
      b.add(utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="${f.key}"\r\n\r\n${f.value}\r\n'));
    }
    for (final f in files.entries) {
      b.add(utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="${f.key}"; filename="${f.key}.jpg"\r\nContent-Type: image/jpeg\r\n\r\n'));
      b.add(f.value);
      b.add(utf8.encode('\r\n'));
    }
    b.add(utf8.encode('--$boundary--\r\n'));
    return b.takeBytes();
  }

  /// The text fields of a report. Kept in one place so the webhook's workflow can rely on them.
  @visibleForTesting
  static Map<String, String> fieldsFor(RoadEvent e) => {
        'event_id': e.id,
        'violation': e.type, // triple_riding | no_helmet
        'timestamp': e.time.toUtc().toIso8601String(),
        'latitude': e.lat!.toString(),
        'longitude': e.lon!.toString(),
        'plate_number': e.plateText,
        'plate_clear': 'true',
        'plate_hires': e.plateHiRes.toString(),
        'authorised': 'true', // a person approved this report in the app
        'source': 'connect-drive-mode',
        if (e.note.isNotEmpty) 'note': e.note,
      };

  /// Sends one authorised violation. Re-checks the rules, so a caller cannot send a report the rules
  /// forbid. On success the event is remembered as reported.
  Future<ReportResult> report(RoadEvent e) async {
    final target = url;
    final block = check(e, configured: target != null, alreadyReported: (await reportedIds()).contains(e.id));
    if (block != ReportBlock.none || target == null) return ReportResult(false, block.name);

    final frame = File(e.framePath);
    final plate = File(e.platePath!);
    if (!await frame.exists() || !await plate.exists()) return const ReportResult(false, 'files missing');

    final boundary = '----connect-${DateTime.now().microsecondsSinceEpoch}';
    final files = <String, List<int>>{'frame': await frame.readAsBytes(), 'plate': await plate.readAsBytes()};
    // The vehicle at full detail, when a full-resolution still was taken.
    final vehicle = e.vehiclePath == null ? null : File(e.vehiclePath!);
    if (vehicle != null && await vehicle.exists()) files['vehicle'] = await vehicle.readAsBytes();
    final body = buildBody(boundary, fieldsFor(e), files);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(target);
      req.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$boundary');
      req.contentLength = body.length;
      req.add(body);
      final resp = await req.close().timeout(timeout);
      await resp.drain<void>();
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        await _markReported(e.id);
        return const ReportResult(true);
      }
      debugPrint('violation report ${e.id} rejected: HTTP ${resp.statusCode}');
      return ReportResult(false, 'HTTP ${resp.statusCode}');
    } on TimeoutException {
      return const ReportResult(false, 'timeout');
    } catch (err) {
      debugPrint('violation report ${e.id} failed: $err');
      return ReportResult(false, '$err');
    } finally {
      client.close(force: true);
    }
  }
}
