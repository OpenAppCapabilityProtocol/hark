import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hark/main.dart';

void main() {
  testWidgets('HarkApp builds and shows the header title', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: HarkApp()));
    await tester.pump();

    expect(find.text('Hark'), findsWidgets);
  });
}
