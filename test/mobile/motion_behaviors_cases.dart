import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/phone_bottom_nav.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/widgets/skeleton.dart';

void main() {
  testWidgets('rapid tab changes finish at the latest tab', (tester) async {
    final index = ValueNotifier(0);
    final reduced = ValueNotifier(false);
    final pressed = <int>[];
    addTearDown(index.dispose);
    addTearDown(reduced.dispose);
    await tester.pumpWidget(
      CupertinoTestApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: reduced,
          builder: (context, disableAnimations, _) => MediaQuery(
            data: MediaQueryData(disableAnimations: disableAnimations),
            child: CupertinoPageScaffold(
              child: ValueListenableBuilder<int>(
                valueListenable: index,
                builder: (context, selected, _) => PhoneTabTransition(
                  index: selected,
                  child: Center(
                    child: AppButton(
                      key: ValueKey('tab-$selected'),
                      onPressed: () => pressed.add(selected),
                      variant: AppButtonVariant.plain,
                      child: Text('tab $selected'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    index.value = 2;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    index.value = 1;
    await tester.pump();
    index.value = 0;
    await tester.pump();
    expect(find.text('tab 0'), findsOneWidget);
    final tabSlide = find.descendant(
      of: find.byType(PhoneTabTransition),
      matching: find.byType(SlideTransition),
    );
    final slide = tester.widget<SlideTransition>(tabSlide);
    expect(slide.position.value.dx, lessThan(0));
    await tester.tap(find.byKey(const ValueKey('tab-0')));
    expect(pressed, [0]);
    await settle(tester);
    expect(slide.position.value, Offset.zero);
    expect(find.text('tab 0'), findsOneWidget);

    index.value = 2;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    reduced.value = true;
    await tester.pump();
    expect(
      tester.widget<SlideTransition>(tabSlide).position.value,
      Offset.zero,
    );
  });

  testWidgets(
    'Cupertino navigation selection is immediate with reduced motion',
    (tester) async {
      Widget app(bool reduced, int index) => CupertinoTestApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: CupertinoPageScaffold(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: PhoneBottomNav(
                index: index,
                floating: false,
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(false, 0));
      expect(
        tester
            .widget<CupertinoTabBar>(find.byType(CupertinoTabBar))
            .currentIndex,
        0,
      );
      await tester.pumpWidget(app(true, 1));
      expect(
        tester
            .widget<CupertinoTabBar>(find.byType(CupertinoTabBar))
            .currentIndex,
        1,
      );
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'skeleton stops when hidden or reduced and resumes when visible',
    (tester) async {
      Widget app({required bool visible, required bool reduced}) =>
          CupertinoTestApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: TickerMode(
                enabled: visible,
                child: const CupertinoPageScaffold(
                  child: SkeletonBlock(width: 120, height: 80),
                ),
              ),
            ),
          );

      BoxDecoration decoration() =>
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: find.byType(SkeletonBlock),
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as BoxDecoration;

      await tester.pumpWidget(app(visible: true, reduced: false));
      expect(decoration().gradient, isA<LinearGradient>());
      await tester.pumpWidget(app(visible: false, reduced: false));
      expect(decoration().gradient, isNull);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(app(visible: true, reduced: true));
      expect(decoration().gradient, isNull);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(app(visible: true, reduced: false));
      expect(decoration().gradient, isA<LinearGradient>());
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TV focus scroll follows the last focused target', (
    tester,
  ) async {
    final nodes = List.generate(8, (_) => FocusNode());
    addTearDown(() {
      for (final node in nodes) {
        node.dispose();
      }
    });
    Widget app(bool reduced) => CupertinoTestApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: CupertinoPageScaffold(
          child: SizedBox(
            height: 220,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (var i = 0; i < nodes.length; i++)
                    SizedBox(
                      height: 100,
                      child: TvAction(
                        focusNode: nodes[i],
                        onPressed: () {},
                        child: Text('target $i'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(app(false));
    nodes[3].requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    nodes[7].requestFocus();
    await tester.pump();
    await settle(tester);
    ScrollPosition position() =>
        tester.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(nodes[7].hasFocus, isTrue);
    expect(position().pixels, greaterThan(400));

    await tester.pumpWidget(app(true));
    nodes[0].requestFocus();
    await tester.pump();
    await tester.pump();
    expect(nodes[0].hasFocus, isTrue);
    expect(
      MediaQuery.disableAnimationsOf(tester.element(find.text('target 0'))),
      isTrue,
    );
    expect(position().pixels, lessThan(200));
    expect(position().isScrollingNotifier.value, isFalse);
  });
}
