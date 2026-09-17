import 'package:flutter_test/flutter_test.dart';

/// Wait for the same scheduled-frame stability and timeout as pumpAndSettle.
/// Intermediate animation frames are painted; update the full semantics tree
/// before returning so subsequent accessibility assertions still see it.
Future<int> settle(WidgetTester tester) async {
  final count = await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.paint,
  );
  await tester.pump(Duration.zero, EnginePhase.sendSemanticsUpdate);
  return count;
}
