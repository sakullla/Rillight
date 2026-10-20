import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/tv_top_nav.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/ui/ui.dart';

import '../helpers/cupertino_test_app.dart';

void main() {
  Widget host({
    required int index,
    required FocusNode home,
    required ValueChanged<int> onSelect,
    required ValueChanged<int> onEnter,
  }) {
    return CupertinoTestApp(
      theme: AppUiTheme.tvDark(),
      home: CupertinoPageScaffold(
        child: Align(
          alignment: Alignment.topLeft,
          child: TvTopNavBar(
            index: index,
            homeNode: home,
            onSelect: onSelect,
            onEnter: onEnter,
          ),
        ),
      ),
    );
  }

  void useTvCanvas(WidgetTester tester) {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('top nav keeps four pane destinations with one selected', (
    tester,
  ) async {
    useTvCanvas(tester);
    final home = FocusNode();
    addTearDown(home.dispose);
    var selected = -1;
    await tester.pumpWidget(
      host(
        index: 2,
        home: home,
        onSelect: (i) => selected = i,
        onEnter: (_) {},
      ),
    );

    for (var i = 0; i < 4; i++) {
      final action = tester.widget<TvAction>(find.byKey(ValueKey('tv-nav-$i')));
      expect(action.selected, i == 2);
    }
    expect(find.byKey(const ValueKey('tv-nav-4')), findsNothing);

    // 当前面板的实心强调指示条只有一条,宽度按 960 画布取 18。
    final widths = [
      for (final element in find.byType(AnimatedContainer).evaluate())
        (element.widget as AnimatedContainer).constraints?.minWidth,
    ];
    expect(widths.where((width) => width == 18), hasLength(1));

    await tester.tap(find.byKey(const ValueKey('tv-nav-3')));
    await tester.pump();
    expect(selected, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('arrow down enters the pane without moving nav focus', (
    tester,
  ) async {
    useTvCanvas(tester);
    final home = FocusNode();
    addTearDown(home.dispose);
    var entered = -1;
    await tester.pumpWidget(
      host(index: 0, home: home, onSelect: (_) {}, onEnter: (i) => entered = i),
    );

    home.requestFocus();
    await tester.pump();
    expect(home.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(entered, 0);
    expect(tester.takeException(), isNull);
  });

  test('TV focus ring and nav reserve stay at their token values', () {
    expect(TvAction.focusRingWidth, 4);
    expect(TvTopNavBar.reserveHeight, 64);
  });
}
