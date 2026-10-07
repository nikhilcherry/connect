import 'package:connect/screens/plate_scan_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('plate screen asks for the full plate before searching', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PlateScanScreen()));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Photograph the plate'), findsOneWidget);
    expect(find.text('Find this car on Connect'), findsOneWidget);
    // Nothing about a found car until a lookup succeeds.
    expect(find.text('Message the owner'), findsNothing);

    await tester.enterText(find.byType(TextField), 'KA01');
    await tester.tap(find.text('Find this car on Connect'));
    await tester.pump();
    expect(find.text('Enter the full number plate.'), findsOneWidget);
  });
}
