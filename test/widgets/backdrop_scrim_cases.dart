import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/widgets/backdrop_scrim.dart';

LinearGradient _gradientOf(WidgetTester tester, Key key) {
  final box = tester.widget<DecoratedBox>(
    find.descendant(of: find.byKey(key), matching: find.byType(DecoratedBox)),
  );
  return (box.decoration as BoxDecoration).gradient! as LinearGradient;
}

Future<void> _pump(
  WidgetTester tester, {
  Widget? backdrop,
  bool disableAnimations = false,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            child: BackdropScrim(backdrop: backdrop),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('BackdropScrim renders three bands over the backdrop', (
    tester,
  ) async {
    await _pump(
      tester,
      backdrop: const ColoredBox(
        key: Key('backdrop'),
        color: Colors.red,
        child: SizedBox.expand(),
      ),
    );

    expect(find.byKey(const Key('backdrop')), findsOneWidget);
    expect(find.byKey(BackdropScrim.topBandKey), findsOneWidget);
    expect(find.byKey(BackdropScrim.textBandKey), findsOneWidget);
    expect(find.byKey(BackdropScrim.bottomBandKey), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);

    final top = _gradientOf(tester, BackdropScrim.topBandKey);
    expect(top.colors.first.a, closeTo(AppScrim.top, 0.01));
    expect(top.colors.last.a, 0);
    expect(
      tester.getSize(find.byKey(BackdropScrim.topBandKey)).height,
      AppScrim.topBandHeight,
    );

    final text = _gradientOf(tester, BackdropScrim.textBandKey);
    expect(text.stops, AppScrim.textStops);
    expect(text.colors[0].a, closeTo(AppScrim.textStart, 0.01));
    expect(text.colors[1].a, closeTo(AppScrim.textMid, 0.01));
    expect(text.colors[2].a, 0);
    expect(
      tester.getSize(find.byKey(BackdropScrim.textBandKey)).width,
      closeTo(800 * AppScrim.textBandWidthFactor, 0.5),
    );

    final bottom = _gradientOf(tester, BackdropScrim.bottomBandKey);
    expect(bottom.stops, AppScrim.bottomStops);
    expect(bottom.colors[0].a, 0);
    expect(bottom.colors[1].a, closeTo(AppScrim.bottomMid, 0.01));
    expect(bottom.colors[2].a, closeTo(1, 0.01));
  });

  testWidgets(
    'BackdropScrim raises opaque stops when animations are disabled',
    (tester) async {
      await _pump(tester, disableAnimations: true);

      for (final key in [
        BackdropScrim.topBandKey,
        BackdropScrim.textBandKey,
        BackdropScrim.bottomBandKey,
      ]) {
        final gradient = _gradientOf(tester, key);
        final opaque = gradient.colors.where((color) => color.a > 0);
        expect(opaque, isNotEmpty, reason: '$key has no opaque stop');
        for (final color in opaque) {
          expect(
            color.a,
            greaterThanOrEqualTo(AppScrim.reduced - 0.01),
            reason: '$key stop alpha ${color.a} below reduced threshold',
          );
        }
        expect(
          gradient.colors.any((color) => color.a == 0),
          isTrue,
          reason: '$key must still fade to transparent',
        );
      }
    },
  );

  testWidgets('BackdropScrim paints the page background without a backdrop', (
    tester,
  ) async {
    await _pump(tester);

    final scrim = find.byType(BackdropScrim);
    final base = tester.widget<ColoredBox>(
      find.descendant(of: scrim, matching: find.byType(ColoredBox)).first,
    );
    expect(base.color, AppTheme.dark().scaffoldBackgroundColor);
    expect(find.byKey(BackdropScrim.topBandKey), findsOneWidget);
    expect(find.byKey(BackdropScrim.textBandKey), findsOneWidget);
    expect(find.byKey(BackdropScrim.bottomBandKey), findsOneWidget);
  });

  testWidgets('BackdropScrim lets taps pass through to widgets beneath', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
              ),
              const BackdropScrim(
                backdrop: ColoredBox(
                  color: Colors.red,
                  child: SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tapAt(const Offset(20, 20));
    expect(taps, 1);
  });
}
