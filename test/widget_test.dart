import 'package:flutter_test/flutter_test.dart';

import 'package:caller_bot/main.dart';

void main() {
  testWidgets('Setup screen renders start button', (WidgetTester tester) async {
    await tester.pumpWidget(const CallerBotApp());
    expect(find.text('Start calling'), findsOneWidget);
    expect(find.text('Phone numbers'), findsOneWidget);
  });
}
