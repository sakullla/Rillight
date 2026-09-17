import 'settle.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app_shell.dart';

/// 顶栏叠在内容上时,控件中心可能落在栏内;点到栏下方仍落在同一控件上的位置。
Future<void> tapBelowTopBar(WidgetTester tester, Finder finder) async {
  final bar = find.byKey(AppShell.topBarKey);
  final rect = tester.getRect(finder);
  var dy = rect.center.dy;
  if (bar.evaluate().isNotEmpty) {
    final barBottom = tester.getRect(bar).bottom;
    if (dy <= barBottom) {
      dy = (barBottom + 1).clamp(rect.top + 1, rect.bottom - 1).toDouble();
    }
  }
  await tester.tapAt(Offset(rect.center.dx, dy));
}

Future<void> ensureVisibleBelowTopBar(
  WidgetTester tester,
  Finder finder,
) async {
  final context = tester.element(finder);
  final scrollable = Scrollable.maybeOf(context);
  if (scrollable == null) {
    await tester.ensureVisible(finder);
    await settle(tester);
    return;
  }
  final viewport = scrollable.position.viewportDimension;
  final bar = find.byKey(AppShell.topBarKey);
  final barBottom = bar.evaluate().isEmpty ? 0.0 : tester.getRect(bar).bottom;
  final alignment = viewport <= 0 ? 0.0 : ((barBottom + 8) / viewport);
  await Scrollable.ensureVisible(
    context,
    alignment: alignment.clamp(0.0, 1.0).toDouble(),
    duration: Duration.zero,
  );
  await settle(tester);
}
