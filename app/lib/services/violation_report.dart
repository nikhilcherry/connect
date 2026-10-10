import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data' show BytesBuilder;

import 'package:crypto/crypto.dart' show sha256;
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

  /// No GPS fix was recorded for this event, so there is no latitude and longitude to send.
  noLocation,

  /// Footage from a video clip that has no recorded time: only when it was scanned is known, and that is wrong.
  noTime,

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
  ViolationReporter({String? url, String? key, this.timeout = const Duration(seconds: 25)})
      : key = key ?? Config.violationWebhookKey,
        url = (url ?? Config.violationWebhookUrl).isEmpty ? null : Uri.parse(url ?? Config.violationWebhookUrl);

  /// Where reports go, or null if this build has none configured.
  final Uri? url;

  /// Sent as `X-Api-Key` when not empty.
  final String key;
  final Duration timeout;

  static const _prefReported = 'reported_violations';
  static const _prefSalt = 'report_anon_salt';

  /// What identifies the event to the reporting service. Reports are anonymous: the id is a one-way hash of
  /// the local id and a random secret kept only on this phone, so it is the same on a retry but cannot be
  /// linked to other reports from this phone, and does not reveal how many there are.
  @visibleForTesting
  Future<String> anonymousId(String localId) async {
    String salt;
    try {
      final p = await SharedPreferences.getInstance();
      var saved = p.getString(_prefSalt);
      if (saved == null) {
        final r = Random.secure();
        saved = List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
        await p.setString(_prefSalt, saved);
      }
      salt = saved;
    } catch (_) {
      salt = 'volatile-${Random.secure().nextInt(1 << 31)}'; // storage unavailable: still unlinkable
    }
    return sha256.convert(utf8.encode('$salt|$localId')).toString().substring(0, 24);
  }

  bool get configured => url != null;

  /// The rule for "may this be reported". Pure, so it can be tested without a network or a phone.
  static ReportBlock check(RoadEvent e, {required bool configured, bool alreadyReported = false}) {
    if (!configured) return ReportBlock.notConfigured;
    if (!e.isViolation) return ReportBlock.notAViolation;
    if (alreadyReported) return ReportBlock.alreadyReported;
    if (!e.hasLocation) return ReportBlock.noLocation;
    if (!e.timeKnown) return ReportBlock.noTime;
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
  static Map<String, String> fieldsFor(RoadEvent e, {String? eventId}) => {
        'event_id': eventId ?? e.id,
        'violation': e.type, // triple_riding | no_helmet
        // To the second: more detail than that identifies nothing useful.
        'timestamp': DateTime.utc(e.time.toUtc().year, e.time.toUtc().month, e.time.toUtc().day, e.time.toUtc().hour,
                e.time.toUtc().minute, e.time.toUtc().second)
            .toIso8601String()
            .replaceFirst('.000', ''),
        'latitude': e.lat!.toString(),
        'longitude': e.lon!.toString(),
        'plate_number': e.plateText,
        'plate_clear': e.plateClear.toString(), // false when the plate was not read; the photo is still sent
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
    if (!await frame.exists()) return const ReportResult(false, 'files missing');
    // The plate crop only exists when a plate was found; a report without one is still sent.
    final plate = e.platePath == null ? null : File(e.platePath!);

    final boundary = '----connect-${Random.secure().nextInt(1 << 31).toRadixString(16)}${Random.secure().nextInt(1 << 31).toRadixString(16)}';
    final files = <String, List<int>>{'frame': await frame.readAsBytes()};
    if (plate != null && await plate.exists()) files['plate'] = await plate.readAsBytes();
    // The vehicle at full detail, when a full-resolution still was taken.
    final vehicle = e.vehiclePath == null ? null : File(e.vehiclePath!);
    if (vehicle != null && await vehicle.exists()) files['vehicle'] = await vehicle.readAsBytes();
    final body = buildBody(boundary, fieldsFor(e, eventId: await anonymousId(e.id)), files);
    // A plain user agent, so the request does not say which runtime or version the app uses.
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'connect-report';
    try {
      final req = await client.postUrl(target);
      req.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$boundary');
      if (key.isNotEmpty) req.headers.set('X-Api-Key', key);
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
