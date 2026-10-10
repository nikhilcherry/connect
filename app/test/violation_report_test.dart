import 'dart:convert';
import 'dart:io';

import 'package:connect/services/roadguard.dart';
import 'package:connect/services/violation_report.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

RoadEvent _event({
  String type = 'no_helmet',
  String plateText = 'KA01AB1234',
  bool plateValid = true,
  String? platePath = 'plate.jpg',
  double? lat = 12.9716,
  double? lon = 77.5946,
  String framePath = 'frame.jpg',
  String id = 'no_helmet_00001',
}) =>
    RoadEvent(
      id: id,
      type: type,
      time: DateTime.utc(2026, 10, 10, 9, 30, 15),
      score: 0.8,
      plateText: plateText,
      plateValid: plateValid,
      note: 'ai: people=1 helmets=x conf=0.9',
      framePath: framePath,
      platePath: platePath,
      lat: lat,
      lon: lon,
    );

void main() {
  group('may this violation be reported', () {
    test('a violation with a clear plate and a location can be', () {
      expect(ViolationReporter.check(_event(), configured: true), ReportBlock.none);
    });

    test('nothing is offered when the build has no webhook', () {
      expect(ViolationReporter.check(_event(), configured: false), ReportBlock.notConfigured);
    });

    test('a pothole is not a traffic violation', () {
      expect(ViolationReporter.check(_event(type: 'pothole'), configured: true), ReportBlock.notAViolation);
    });

    test('a violation is reportable even when the plate was not read', () {
      expect(ViolationReporter.check(_event(platePath: null), configured: true), ReportBlock.none);
      expect(ViolationReporter.check(_event(plateValid: false, plateText: 'XQ7'), configured: true), ReportBlock.none);
      expect(ViolationReporter.check(_event(plateText: ''), configured: true), ReportBlock.none);
    });

    test('without a GPS fix there is no latitude and longitude to send', () {
      expect(ViolationReporter.check(_event(lat: null), configured: true), ReportBlock.noLocation);
      expect(ViolationReporter.check(_event(lon: null), configured: true), ReportBlock.noLocation);
    });

    test('a violation is reported once', () {
      expect(ViolationReporter.check(_event(), configured: true, alreadyReported: true), ReportBlock.alreadyReported);
    });
  });

  group('what is sent', () {
    test('the fields carry the plate, the time and the coordinates', () {
      final f = ViolationReporter.fieldsFor(_event());
      expect(f['violation'], 'no_helmet');
      expect(f['latitude'], '12.9716');
      expect(f['longitude'], '77.5946');
      expect(f['plate_number'], 'KA01AB1234');
      expect(f['plate_clear'], 'true');
      // An unread plate is flagged, not hidden, so the workflow can tell the difference.
      final unread = ViolationReporter.fieldsFor(_event(platePath: null, plateText: ''));
      expect(unread['plate_clear'], 'false');
      expect(unread['plate_number'], '');
      expect(f['authorised'], 'true');
      expect(f['timestamp'], '2026-10-10T09:30:15.000Z');
    });

    test('the body is a multipart form with the text fields and both photos', () {
      final body = ViolationReporter.buildBody('BOUND', {'a': '1'}, {'frame': [1, 2, 3], 'plate': [4, 5]});
      final text = latin1.decode(body);
      expect(text, contains('--BOUND\r\nContent-Disposition: form-data; name="a"\r\n\r\n1\r\n'));
      expect(text, contains('name="frame"; filename="frame.jpg"'));
      expect(text, contains('name="plate"; filename="plate.jpg"'));
      expect(text, endsWith('--BOUND--\r\n'));
    });
  });

  group('sending to a server', () {
    late Directory dir;
    late HttpServer server;
    final received = <Map<String, Object>>[];
    int status = 200;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dir = await Directory.systemTemp.createTemp('report_test');
      File('${dir.path}/frame.jpg').writeAsBytesSync([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);
      File('${dir.path}/plate.jpg').writeAsBytesSync([0xFF, 0xD8, 9, 8, 0xFF, 0xD9]);
      received.clear();
      status = 200;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final bytes = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        received.add({'method': req.method, 'path': req.uri.path, 'type': req.headers.contentType.toString(), 'body': latin1.decode(bytes)});
        req.response.statusCode = status;
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      await dir.delete(recursive: true);
    });

    ViolationReporter reporter() => ViolationReporter(url: 'http://127.0.0.1:${server.port}/webhook/traffic-violation');
    RoadEvent event({double? lat = 12.9716}) => _event(framePath: '${dir.path}/frame.jpg', platePath: '${dir.path}/plate.jpg', lat: lat);

    test('an authorised violation is posted with both photos and the coordinates', () async {
      final r = await reporter().report(event());
      expect(r.ok, isTrue);
      expect(received, hasLength(1));
      final got = received.single;
      expect(got['method'], 'POST');
      expect(got['path'], '/webhook/traffic-violation');
      expect(got['type'] as String, startsWith('multipart/form-data'));
      final body = got['body'] as String;
      expect(body, contains('name="latitude"\r\n\r\n12.9716'));
      expect(body, contains('name="longitude"\r\n\r\n77.5946'));
      expect(body, contains('name="plate_number"\r\n\r\nKA01AB1234'));
      expect(body, contains('name="frame"; filename="frame.jpg"'));
      expect(body, contains('name="plate"; filename="plate.jpg"'));
    });

    test('a violation whose plate was not read is still posted, flagged as not clear', () async {
      final noPlate = _event(framePath: '${dir.path}/frame.jpg', platePath: null, plateText: '', plateValid: false);
      final r = await reporter().report(noPlate);
      expect(r.ok, isTrue);
      final body = received.single['body'] as String;
      expect(body, contains('name="plate_clear"\r\n\r\nfalse'));
      expect(body, contains('name="latitude"\r\n\r\n12.9716'));
      expect(body, contains('name="frame"; filename="frame.jpg"'));
      expect(body, isNot(contains('name="plate"; filename')));
    });

    test('it is remembered as reported and is not sent twice', () async {
      final rep = reporter();
      expect((await rep.report(event())).ok, isTrue);
      expect(await rep.reportedIds(), contains('no_helmet_00001'));
      final again = await rep.report(event());
      expect(again.ok, isFalse);
      expect(again.detail, 'alreadyReported');
      expect(received, hasLength(1));
    });

    test('a violation the rules forbid never reaches the network', () async {
      final r = await reporter().report(event(lat: null));
      expect(r.ok, isFalse);
      expect(r.detail, 'noLocation');
      expect(received, isEmpty);
    });

    test('a server error is a failure and is not remembered as reported', () async {
      status = 500;
      final rep = reporter();
      final r = await rep.report(event());
      expect(r.ok, isFalse);
      expect(r.detail, 'HTTP 500');
      expect(await rep.reportedIds(), isEmpty);
    });

    test('a build without a webhook sends nothing', () async {
      final r = await ViolationReporter(url: '').report(event());
      expect(r.ok, isFalse);
      expect(r.detail, 'notConfigured');
      expect(received, isEmpty);
    });
  });
}
