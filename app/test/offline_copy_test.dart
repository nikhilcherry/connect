import 'dart:convert';

import 'package:connect/data/app_state.dart';
import 'package:connect/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rows as the server returns them, after a trip through JSON as the saved copy makes.
Map<String, dynamic> _saved({Map<String, dynamic>? tag}) => jsonDecode(jsonEncode({
      'user': 'me',
      'vehicles': [
        {'id': 'v-shared', 'owner': 'someone', 'reg_number': 'KA05MN4321', 'make': 'Honda', 'model': 'City'},
        {
          'id': 'v-mine',
          'owner': 'me',
          'reg_number': 'KA01AB1234',
          'make': 'Maruti Suzuki',
          'model': 'Swift',
          'colour': 'Red',
          'length_mm': 3860,
          'puc_expiry': '2026-12-01',
          'back_at': '2026-10-09T13:00:00+00:00',
          'medical_share': true,
        },
      ],
      'tag': tag ?? {'code': 'EE5WRD6P', 'vehicle_id': 'v-mine', 'active': true},
      'alerts': [
        {
          'id': 'a1',
          'vehicle_id': 'v-mine',
          'kind': 'lights_on',
          'status': 'open',
          'blocked': false,
          'scanner_lang': 'kn',
          'created_at': '2026-10-09T10:00:00+00:00',
          'updated_at': '2026-10-09T10:00:00+00:00',
        },
      ],
      'contacts': [
        {'id': 'c1', 'name': 'Asha', 'phone': '+911234567890'},
      ],
      'family': [
        {'member': 'u2', 'display_name': 'Priya', 'created_at': '2026-10-01T10:00:00+00:00'},
      ],
      'societies': [
        {'id': 's1', 'name': 'Palm Grove', 'admin': 'me'},
      ],
      'notices': [
        {'id': 7, 'society_id': 's1', 'body': 'Gate closed Sunday', 'created_at': '2026-10-08T10:00:00+00:00'},
      ],
    })) as Map<String, dynamic>;

void main() {
  test('the saved copy brings back the car, its tag and the alerts', () {
    final r = AppState.restoreRows(_saved(), 'me', null);
    expect(r.vehicles, hasLength(2));
    expect(r.vehicle!.id, 'v-mine', reason: 'your own car comes before one shared with you');
    expect(r.vehicle!.prettyReg, 'KA 01 AB 1234');
    expect(r.vehicle!.lengthMm, 3860);
    expect(r.vehicle!.medicalShare, isTrue);
    expect(r.tag!.code, 'EE5WRD6P');
    expect(r.alerts.single.kind, AlertKind.lightsOn);
    expect(r.alerts.single.scannerLang.code, 'kn');
    expect(r.contacts.single.name, 'Asha');
    expect(r.family.single.name, 'Priya');
    expect(r.societies.single.isAdmin, isTrue);
    expect(r.notices.single.body, 'Gate closed Sunday');
  });

  test('the car that was chosen stays chosen', () {
    final r = AppState.restoreRows(_saved(), 'me', 'v-shared');
    expect(r.vehicle!.id, 'v-shared');
    expect(r.tag, isNull, reason: 'the saved tag belongs to the other car; showing it here would be a lie');
  });

  test('a copy with no car restores to nothing to show', () {
    final r = AppState.restoreRows({'user': 'me', 'vehicles': <dynamic>[]}, 'me', null);
    expect(r.vehicle, isNull);
    expect(r.alerts, isEmpty);
  });
}
