import 'package:connect/data/models.dart';
import 'package:connect/screens/whisper_screen.dart';
import 'package:connect/services/whisper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WhisperStore.reset();
  });

  testWidgets('the sound screen wants a whole plate and shows what the phone is carrying', (tester) async {
    await WhisperStore.add(const Whisper(plate: 'KA01AB1234', kind: AlertKind.lightsOn, nonce: 1), mine: true);
    await WhisperStore.add(const Whisper(plate: 'MH12DE1433', kind: AlertKind.towing, nonce: 2), mine: false, own: true);

    await tester.pumpWidget(const MaterialApp(home: WhisperScreen(plate: 'KA05')));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('No signal? Say it with sound'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'KA05'), findsOneWidget, reason: 'the plate handed over by the plate screen');
    // Every reason a stranger can pick on the scan page can be sent by sound too.
    for (final k in AlertKind.values) {
      expect(find.widgetWithText(ChoiceChip, k.label), findsOneWidget);
    }

    await tester.tap(find.text('Send by sound'));
    await tester.pump();
    expect(find.text('Enter the full number plate.'), findsOneWidget);

    await tester.scrollUntilVisible(find.textContaining('MH12DE1433'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('MH12DE1433 · Sent by you'), findsOneWidget);
    expect(find.textContaining('KA01AB1234 · About your car'), findsOneWidget);
    expect(find.text('CARRYING'), findsNWidgets(2));
  });
}
