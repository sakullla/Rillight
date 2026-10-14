import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/ui/ui.dart';

Widget _app(Widget child) => CupertinoApp(
  locale: const Locale('zh'),
  localizationsDelegates: GlobalCupertinoLocalizations.delegates,
  supportedLocales: const [Locale('zh')],
  home: AppUiTheme(
    data: AppUiTheme.light(),
    child: CupertinoPageScaffold(child: child),
  ),
);

void main() {
  testWidgets('switch label, switch and keyboard each toggle once', (
    tester,
  ) async {
    var value = false;
    var changes = 0;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, update) => Center(
            child: AppSwitchTile(
              title: const Text('启用字幕'),
              value: value,
              onChanged: (next) => update(() {
                value = next;
                changes++;
              }),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('启用字幕'));
    await tester.pump();
    expect(value, isTrue);
    expect(changes, 1);
    await tester.tap(find.byType(CupertinoSwitch));
    await tester.pump();
    expect(value, isFalse);
    expect(changes, 2);
    final focus = tester.widget<FocusableActionDetector>(
      find.byType(FocusableActionDetector).first,
    );
    expect(focus.enabled, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(value, isTrue);
    expect(changes, 3);
  });

  testWidgets('pull refresh cancels when drag reverses and completes once', (
    tester,
  ) async {
    var refreshes = 0;
    final complete = Completer<void>();
    await tester.pumpWidget(
      _app(
        AppRefresh(
          onRefresh: () {
            refreshes++;
            return complete.future;
          },
          child: ListView(
            physics: const ClampingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            children: const [SizedBox(height: 1800, child: Text('内容'))],
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(200, 180));
    await gesture.moveBy(const Offset(0, 110));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -150));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(refreshes, 0);
    tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(0);
    await tester.drag(find.byType(ListView), const Offset(0, 140));
    await tester.pump();
    expect(refreshes, 1);
    complete.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
  });

  testWidgets(
    'notice dismissal is idempotent before mount and after disposal',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      );
      final dismiss = showAppNotice(context, '已保存');
      dismiss();
      dismiss();
      await tester.pump();
      expect(find.text('已保存'), findsNothing);
      final afterDispose = showAppNotice(context, '待关闭');
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      afterDispose();
      afterDispose();
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    },
  );
}
