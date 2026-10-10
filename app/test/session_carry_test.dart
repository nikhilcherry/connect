import 'package:connect/config.dart';
import 'package:connect/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const tunnel = 'https://connect-api.premortem.tech', cable = 'http://127.0.0.1:54321';

  test('the session is filed under a name taken from the address', () {
    expect(Config.sessionKey(cable), 'sb-127-auth-token');
    expect(Config.sessionKey(tunnel), 'sb-connect-api-auth-token');
    expect(Config.sessionKey('https://abcdefghijkl.supabase.co'), 'sb-abcdefghijkl-auth-token');
  });

  test('a build with a new address for the same backend keeps the account', () async {
    SharedPreferences.setMockInitialValues({'sb-127-auth-token': '{"access_token":"a"}', 'app_lang': 'kn'});
    final prefs = await SharedPreferences.getInstance();
    await carrySessionOver(prefs, tunnel);
    expect(prefs.getString('sb-connect-api-auth-token'), '{"access_token":"a"}');
    expect(prefs.getString('app_lang'), 'kn');
  });

  test('a session already there is left alone', () async {
    SharedPreferences.setMockInitialValues({'sb-127-auth-token': 'old', 'sb-connect-api-auth-token': 'current'});
    final prefs = await SharedPreferences.getInstance();
    await carrySessionOver(prefs, tunnel);
    expect(prefs.getString('sb-connect-api-auth-token'), 'current');
  });

  test('with two old sessions there is no telling which is this backend\'s, so neither is used', () async {
    SharedPreferences.setMockInitialValues({'sb-127-auth-token': 'a', 'sb-10-auth-token': 'b'});
    final prefs = await SharedPreferences.getInstance();
    await carrySessionOver(prefs, tunnel);
    expect(prefs.containsKey('sb-connect-api-auth-token'), isFalse);
  });

  test('a first launch has nothing to carry', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await carrySessionOver(prefs, tunnel);
    expect(prefs.getKeys(), isEmpty);
  });
}
