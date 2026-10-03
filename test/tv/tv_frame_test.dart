import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/tv_widgets.dart';

void main() {
  testWidgets(
    'reduced motion keeps a focus ring that is not only scale or fill color',
    (tester) async {
      for (final theme in [AppTheme.dark(), AppTheme.light()]) {
        final first = FocusNode();
        final second = FocusNode();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          first.dispose();
          second.dispose();
        });
        // A new FocusNode must attach to a new TvAction state.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: Scaffold(
              body: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TvAction(
                      key: const Key('first'),
                      focusNode: first,
                      onPressed: () {},
                      child: const Text('播放'),
                    ),
                    TvAction(
                      key: const Key('second'),
                      focusNode: second,
                      onPressed: () {},
                      child: const Text('详情'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(_border(tester, 'first').top.color.a, 0);
        expect(_border(tester, 'second').top.color.a, 0);

        first.requestFocus();
        // Focus lands on the next frame. Elapsed time stays zero, so a fade-in
        // cannot finish; the ring has to be fully painted.
        await tester.pump();
        await tester.pump();

        expect(first.hasFocus, isTrue);
        expect(
          MediaQuery.disableAnimationsOf(
            tester.element(find.byKey(const Key('first'))),
          ),
          isTrue,
        );
        _expectFocusRing(tester, 'first', theme.colorScheme);
        expect(_border(tester, 'second').top.color.a, 0);

        second.requestFocus();
        await tester.pump();
        await tester.pump();

        expect(_border(tester, 'first').top.color.a, 0);
        _expectFocusRing(tester, 'second', theme.colorScheme);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'TvFrame padding stays at max(48, 5% of the viewport) inside SafeArea',
    (tester) async {
      Future<void> expectGutter(Size size, {FakeViewPadding? inset}) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.padding = inset ?? FakeViewPadding();
        tester.view.viewPadding = inset ?? FakeViewPadding();
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            home: const TvFrame(title: '片库', child: SizedBox.expand()),
          ),
        );
        await tester.pump();

        final horizontal = math.max(48.0, size.width * 0.05);
        final vertical = math.max(48.0, size.height * 0.05);
        expect(horizontal, greaterThanOrEqualTo(48));
        expect(vertical, greaterThanOrEqualTo(48));

        final safe = tester.widget<SafeArea>(find.byType(SafeArea));
        final padding = safe.child as Padding;
        final insets = padding.padding as EdgeInsets;
        expect(insets.left, horizontal);
        expect(insets.right, horizontal);
        expect(insets.top, vertical);
        expect(insets.bottom, vertical);

        final outer = tester.getRect(find.byWidget(padding));
        final inner = tester.getRect(
          find.descendant(
            of: find.byWidget(padding),
            matching: find.byType(Column),
          ),
        );
        expect(inner.left - outer.left, closeTo(horizontal, 0.01));
        expect(outer.right - inner.right, closeTo(horizontal, 0.01));
        expect(inner.top - outer.top, closeTo(vertical, 0.01));
        expect(outer.bottom - inner.bottom, closeTo(vertical, 0.01));
        expect(inner.left, greaterThanOrEqualTo(horizontal));
        expect(inner.top, greaterThanOrEqualTo(vertical));
        expect(size.width - inner.right, greaterThanOrEqualTo(horizontal));
        expect(size.height - inner.bottom, greaterThanOrEqualTo(vertical));
      }

      await expectGutter(const Size(800, 600));
      await expectGutter(const Size(960, 540));
      await expectGutter(const Size(1920, 1080));
      await expectGutter(const Size(3840, 2160));
      await expectGutter(
        const Size(1920, 1080),
        inset: const FakeViewPadding(left: 30, top: 30, right: 30, bottom: 30),
      );
    },
  );
}

Border _border(WidgetTester tester, String key) {
  final decoration =
      tester
              .widget<DecoratedBox>(
                find.descendant(
                  of: find.byKey(Key(key)),
                  matching: find.byType(DecoratedBox),
                ),
              )
              .decoration
          as BoxDecoration;
  return decoration.border! as Border;
}

void _expectFocusRing(WidgetTester tester, String key, ColorScheme scheme) {
  final decoration =
      tester
              .widget<DecoratedBox>(
                find.descendant(
                  of: find.byKey(Key(key)),
                  matching: find.byType(DecoratedBox),
                ),
              )
              .decoration
          as BoxDecoration;
  final border = decoration.border! as Border;
  final fill = decoration.color!;
  for (final side in [border.top, border.right, border.bottom, border.left]) {
    expect(side.width, greaterThanOrEqualTo(TvAction.focusRingWidth));
    expect(side.width, greaterThanOrEqualTo(4));
    expect(side.color, scheme.onSurface);
    expect(side.color.a, 1);
  }
  // A fill recolor or scale is not the mark; the ring has to stand off the fill.
  expect(fill, isNot(scheme.onSurface));
  expect(_contrast(scheme.onSurface, fill), greaterThanOrEqualTo(3));
}

double _contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  final lighter = math.max(first, second);
  final darker = math.min(first, second);
  return (lighter + 0.05) / (darker + 0.05);
}
