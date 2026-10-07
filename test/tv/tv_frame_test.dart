import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/tv_widgets.dart';

void main() {
  testWidgets(
    'reduced motion still shows focus as an instant high-contrast inverted fill',
    (tester) async {
      for (final theme in [AppTheme.tvDark(), AppTheme.tvLight()]) {
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
        final scheme = theme.colorScheme;
        final page = theme.scaffoldBackgroundColor;

        _expectRest(tester, 'first', scheme);
        _expectRest(tester, 'second', scheme);

        first.requestFocus();
        // Focus lands on the next frame. Elapsed time stays zero, so a fade-in
        // cannot finish; the inverted fill has to be fully painted.
        await tester.pump();
        await tester.pump();

        expect(first.hasFocus, isTrue);
        _expectFocused(tester, 'first', scheme, page);
        _expectRest(tester, 'second', scheme);

        second.requestFocus();
        await tester.pump();
        await tester.pump();

        _expectRest(tester, 'first', scheme);
        _expectFocused(tester, 'second', scheme, page);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'TvFrame header sits inside the 5% safe area and content keeps full width',
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

        late EdgeInsets content;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.tvDark(),
            home: TvFrame(
              title: '片库',
              child: Builder(
                builder: (context) {
                  content = TvFrame.contentPadding(context);
                  return const SizedBox.expand(key: Key('body'));
                },
              ),
            ),
          ),
        );
        await tester.pump();

        final horizontal = math.max(48.0, size.width * 0.05);
        final vertical = math.max(24.0, size.height * 0.05);
        final header = tester.widget<Padding>(
          find.byKey(const Key('tv-frame-header')),
        );
        final insets = header.padding as EdgeInsets;
        expect(insets.left, horizontal);
        expect(insets.right, horizontal);
        expect(insets.top, vertical);

        // Content scrolls edge to edge so focus scale is never clipped;
        // it applies the same gutters as its own scroll padding.
        expect(content.left, horizontal);
        expect(content.right, horizontal);
        expect(content.bottom, vertical);
        final safe = inset == null ? 0.0 : 30.0;
        final body = tester.getRect(find.byKey(const Key('body')));
        expect(body.left, safe);
        expect(body.right, size.width - safe);
      }

      await expectGutter(const Size(960, 540));
      await expectGutter(const Size(1280, 720));
      await expectGutter(const Size(1920, 1080));
      await expectGutter(const Size(3840, 2160));
      await expectGutter(
        const Size(1920, 1080),
        inset: const FakeViewPadding(left: 30, top: 30, right: 30, bottom: 30),
      );
    },
  );

  testWidgets('TV sizes scale with the logical canvas, not physical pixels', (
    tester,
  ) async {
    // 4K 面板 DPR 4 与 1080p 面板 DPR 2 的逻辑画布都是 960×540。
    for (final (physical, ratio) in [
      (const Size(1920, 1080), 2.0),
      (const Size(3840, 2160), 4.0),
    ]) {
      tester.view.physicalSize = physical;
      tester.view.devicePixelRatio = ratio;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late double scale;
      late int poster;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              scale = TvDesign.scaleOf(context);
              poster = TvCardMetrics.of(context).imageMaxWidth;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(scale, 1);
      // 图片按物理像素请求:4K 面板拉到约 4 倍宽,不会被放大发虚。
      expect(poster, (TvDesign.posterWidth * ratio).round());
    }
    // 1280×720 逻辑画布的机型整体放大 4/3。
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.5;
    late double scale;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            scale = TvDesign.scaleOf(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(scale, closeTo(4 / 3, .001));
  });
}

BoxDecoration _decoration(WidgetTester tester, String key) =>
    tester
            .widget<DecoratedBox>(
              find.descendant(
                of: find.byKey(Key(key)),
                matching: find.byType(DecoratedBox),
              ),
            )
            .decoration
        as BoxDecoration;

void _expectRest(WidgetTester tester, String key, ColorScheme scheme) {
  final fill = _decoration(tester, key).color!;
  expect(fill, isNot(scheme.inverseSurface));
  // 静止态是半透明的前景色薄底,不是实色块。
  expect(fill.a, lessThan(.3));
}

void _expectFocused(
  WidgetTester tester,
  String key,
  ColorScheme scheme,
  Color page,
) {
  final fill = _decoration(tester, key).color!;
  expect(fill, scheme.inverseSurface);
  expect(fill.a, 1);
  // 反相实底与页面底色、与其上的文字都高对比。
  expect(_contrast(fill, page), greaterThanOrEqualTo(3));
  expect(_contrast(fill, scheme.onInverseSurface), greaterThanOrEqualTo(4.5));
  final text = tester.widget<RichText>(
    find.descendant(of: find.byKey(Key(key)), matching: find.byType(RichText)),
  );
  expect(text.text.style?.color, scheme.onInverseSurface);
}

double _contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  final lighter = math.max(first, second);
  final darker = math.min(first, second);
  return (lighter + 0.05) / (darker + 0.05);
}
