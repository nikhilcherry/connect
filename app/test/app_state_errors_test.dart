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

  test('database permission errors are not offline', () {
    const e = PostgrestException(message: 'permission denied', code: '42501');
    expect(AppState.isNetworkError(e), isFalse);
    expect(AppState.errorCode(e), 'db 42501');
  });
}
