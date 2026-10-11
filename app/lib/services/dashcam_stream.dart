import 'package:shared_preferences/shared_preferences.dart';

/// Why a dashcam address could not be used.
enum DashcamAddressError { empty, rtsp, notHttp, noHost }

/// The address of a dashcam's live view, as the person typed it: made tidy, or the reason it will not do.
///
/// Wi-Fi dashcams and phone-as-camera apps serve their live preview as MJPEG over plain HTTP (for example
/// `http://192.168.1.254:8192`). RTSP is the other common choice and is not supported yet.
class DashcamAddress {
  const DashcamAddress._(this.url, this.error);

  /// A usable `http://host[:port]/path`, or null when there is [error].
  final String? url;
  final DashcamAddressError? error;

  bool get ok => url != null;

  static DashcamAddress parse(String input) {
    var s = input.trim();
    if (s.isEmpty) return const DashcamAddress._(null, DashcamAddressError.empty);
    final lower = s.toLowerCase();
    if (lower.startsWith('rtsp://') || lower.startsWith('rtsps://')) return const DashcamAddress._(null, DashcamAddressError.rtsp);
    if (!lower.contains('://')) s = 'http://$s';
    final u = Uri.tryParse(s);
    if (u == null || u.scheme.toLowerCase() != 'http') return const DashcamAddress._(null, DashcamAddressError.notHttp);
    if (u.host.isEmpty) return const DashcamAddress._(null, DashcamAddressError.noHost);
    return DashcamAddress._(u.toString(), null);
  }

  static const _pref = 'dashcam_stream_url';

  /// The address used last time, so it need not be typed again in the car.
  static Future<String> lastUsed() async {
    try {
      return (await SharedPreferences.getInstance()).getString(_pref) ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> remember(String url) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_pref, url);
    } catch (_) {}
  }
}
