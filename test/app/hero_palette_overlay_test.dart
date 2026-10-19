import 'package:flutter_test/flutter_test.dart' hide testWidgets;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:rillight/app/artwork_color_scope.dart';
import 'package:rillight/app/theme/brand.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/widgets/hero_palette_overlay.dart';

import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';

/// Reports a frame from inside [HeroPaletteOverlay], the way HeroArtwork and
/// MediaImage do while building.
class _Reporter extends StatelessWidget {
  const _Reporter({required this.paletteKey, required this.bytes});

  final String paletteKey;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    ArtworkColorScope.maybeOf(context)?.report('movie', paletteKey, bytes);
    return const SizedBox.expand();
  }
}

void main() {
  testWidgets('only the active palette key tints the overlay', (tester) async {
    final red = (await tester.runAsync(
      () => _solidPng(const Color(0xffff3b30)),
    ))!;
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: HeroPaletteOverlay(
          paletteKey: 'scope/movie/Backdrop/active',
          child: _Reporter(
            paletteKey: 'scope/next/Backdrop/prefetch',
            bytes: red,
          ),
        ),
      ),
    );
    await _settleMood(tester);
    // A neighbouring PageView page reports first; it must not tint the
    // visible slide while the active key is still missing.
    expect(
      _gradient(tester).colors.first,
      AppBrand.pink.withValues(alpha: .10),
    );

    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: HeroPaletteOverlay(
          paletteKey: 'scope/movie/Backdrop/active',
          child: _Reporter(
            paletteKey: 'scope/movie/Backdrop/active',
            bytes: red,
          ),
        ),
      ),
    );
    await _settleMood(tester);
    final first = _gradient(tester).colors.first;
    expect(_hueDistance(HSLColor.fromColor(first).hue, 2.5), lessThan(15));
    expect(first.a, greaterThan(0));
  });

  testWidgets('first stop follows the poster hue, not the cyan light', (
    tester,
  ) async {
    final blue = (await tester.runAsync(
      () => _solidPng(const Color(0xff1e5cff)),
    ))!;
    const key = 'scope/movie/Backdrop/blue';
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: HeroPaletteOverlay(
          paletteKey: key,
          child: _Reporter(paletteKey: key, bytes: blue),
        ),
      ),
    );
    await _settleMood(tester);
    final gradient = _gradient(tester);
    expect(gradient.stops, orderedEquals(const [0, .55, .78, 1]));
    final moodHue = HSLColor.fromColor(gradient.colors.first).hue;
    final cyanHue = HSLColor.fromColor(AppBrand.cyan).hue;
    expect(_hueDistance(moodHue, 220), lessThan(15));
    expect(_hueDistance(moodHue, cyanHue), greaterThan(15));
    // 300–400ms crossfade; reduced motion collapses it to zero.
    final container = tester.widget<AnimatedContainer>(
      find.byKey(HeroPaletteOverlay.overlayKey),
    );
    expect(container.duration, AppMotion.slow);
  });

  testWidgets('neutral artwork keeps the brand fallback above the image', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: HeroPaletteOverlay(
          paletteKey: 'scope/movie/Backdrop/none',
          child: const SizedBox.expand(),
        ),
      ),
    );
    final gradient = _gradient(tester);
    expect(gradient.colors.first, AppBrand.pink.withValues(alpha: .10));
    expect(gradient.colors.last, AppInk.transparent);
    final overlay = tester.widget<AnimatedContainer>(
      find.byKey(HeroPaletteOverlay.overlayKey),
    );
    expect(
      (overlay.decoration! as BoxDecoration).gradient,
      isA<LinearGradient>(),
    );
    // 覆盖层永远不拦截点击。
    final hitTestWrappers = tester
        .widgetList<IgnorePointer>(
          find.ancestor(
            of: find.byKey(HeroPaletteOverlay.overlayKey),
            matching: find.byType(IgnorePointer),
          ),
        )
        .where((wrapper) => wrapper.ignoring);
    expect(hitTestWrappers, isNotEmpty);
  });

  for (final brightness in Brightness.values) {
    test('light and dark generate matching depth', () {
      final mood = ArtworkMood.fromSeed(const Color(0xffff3b30));
      final gradient = HeroPaletteOverlay.gradientFor(brightness, mood);
      final hsl = HSLColor.fromColor(gradient.colors.first);
      expect(
        hsl.lightness,
        closeTo(brightness == Brightness.dark ? .22 : .90, .001),
      );
      expect(
        gradient.colors.first.a,
        closeTo(brightness == Brightness.dark ? .18 : .16, .001),
      );
    });
  }
}

LinearGradient _gradient(WidgetTester tester) {
  final container = tester.widget<AnimatedContainer>(
    find.byKey(HeroPaletteOverlay.overlayKey),
  );
  return (container.decoration! as BoxDecoration).gradient! as LinearGradient;
}

double _hueDistance(double a, double b) {
  final diff = (a - b).abs() % 360;
  return diff > 180 ? 360 - diff : diff;
}

Future<Uint8List> _solidPng(Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 32, 32), Paint()..color = color);
  final image = await recorder.endRecording().toImage(32, 32);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<void> _settleMood(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}
