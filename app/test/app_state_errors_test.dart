import 'dart:async';

import 'package:connect/data/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('anonymous sign-ins disabled is a server problem, not "offline"', () {
    final e = AuthApiException('Anonymous sign-ins are disabled', statusCode: '422', code: 'anonymous_provider_disabled');
    expect(AppState.isNetworkError(e), isFalse);
    expect(AppState.errorCode(e), 'auth anonymous_provider_disabled');
  });

  test('connection failures are offline', () {
    expect(AppState.isNetworkError(AuthRetryableFetchException(message: 'Failed host lookup')), isTrue);
    expect(AppState.isNetworkError(TimeoutException('slow')), isTrue);
  });

  test('a proxy answering for a server that is down is offline too', () {
    // What the phones saw when the tunnel in front of the backend dropped.
    const tunnel = PostgrestException(message: 'error code: 1033', code: '530');
    expect(AppState.isNetworkError(tunnel), isTrue);
    expect(AppState.isNetworkError(AuthException('Bad Gateway', statusCode: '502')), isTrue);
    expect(AppState.isNetworkError(const PostgrestException(message: 'boom', code: '500')), isFalse);
  });

  test('database permission errors are not offline', () {
    const e = PostgrestException(message: 'permission denied', code: '42501');
    expect(AppState.isNetworkError(e), isFalse);
    expect(AppState.errorCode(e), 'db 42501');
  });
}
