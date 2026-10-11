import 'package:connect/services/dashcam_stream.dart';
import 'package:connect/services/roadguard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('a dashcam address', () {
    test('a full http address is kept', () {
      final a = DashcamAddress.parse('http://192.168.1.254:8192');
      expect(a.ok, isTrue);
      expect(a.url, 'http://192.168.1.254:8192');
    });

    test('a bare host and port gets http, and a path and sign-in are kept', () {
      expect(DashcamAddress.parse('192.168.1.254:8192').url, 'http://192.168.1.254:8192');
      expect(DashcamAddress.parse('  http://cam.local/video?res=hd  ').url, 'http://cam.local/video?res=hd');
      expect(DashcamAddress.parse('http://admin:1234@192.168.0.10:8080/video').url, 'http://admin:1234@192.168.0.10:8080/video');
    });

    test('empty, rtsp and other schemes are refused with the reason', () {
      expect(DashcamAddress.parse('   ').error, DashcamAddressError.empty);
      expect(DashcamAddress.parse('rtsp://192.168.1.254/xxx.mov').error, DashcamAddressError.rtsp);
      expect(DashcamAddress.parse('RTSP://192.168.1.254/xxx.mov').error, DashcamAddressError.rtsp);
      expect(DashcamAddress.parse('https://192.168.1.254').error, DashcamAddressError.notHttp);
      expect(DashcamAddress.parse('ftp://192.168.1.254').error, DashcamAddressError.notHttp);
      expect(DashcamAddress.parse('http://').error, DashcamAddressError.noHost);
    });

    test('the last address is remembered', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await DashcamAddress.lastUsed(), '');
      await DashcamAddress.remember('http://192.168.1.254:8192');
      expect(await DashcamAddress.lastUsed(), 'http://192.168.1.254:8192');
    });
  });

  group('the live stream status', () {
    test('is read from the native side', () {
      final s = RoadStatus.fromMap({'streamHost': '192.168.1.254', 'streamState': 'live'});
      expect(s.streamHost, '192.168.1.254');
      expect(s.streamState, 'live');
      final none = RoadStatus.fromMap({});
      expect(none.streamHost, '');
    });
  });
}
