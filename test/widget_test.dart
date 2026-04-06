import 'package:flutter_test/flutter_test.dart';

import 'package:hark/main.dart';

void main() {
  testWidgets('App builds without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const AssistantApp());

    expect(find.text('OACP Assistant'), findsOneWidget);
  });
}
