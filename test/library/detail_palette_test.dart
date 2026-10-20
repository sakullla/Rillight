import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/artwork_color_scope.dart';
import 'package:rillight/app/artwork_theme_source.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/widgets/hero_palette_overlay.dart';
import 'package:rillight/media_server/models.dart';

import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';

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
  testWidgets('detail surfaces follow the canonical backdrop, not the poster', (
    tester,
  ) async {
    ContentTheme.debugClear();
    final blue = (await tester.runAsync(
      () => _solidPng(const Color(0xff1e5cff)),
    ))!;
    final red = (await tester.runAsync(
      () => _solidPng(const Color(0xffff3b30)),
    ))!;
    late ArtworkColorScope report;
    late AppColorScheme scheme;
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.light(),
        home: ContentTheme(
          item: const MediaItem(
            id: 'movie',
            name: '',
            type: 'Movie',
            backdropImageTag: 'back',
            primaryImageTag: 'poster',
          ),
          child: Builder(
            builder: (context) {
              report = ArtworkColorScope.maybeOf(context)!;
              scheme = AppUiTheme.of(context).colorScheme;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final base = AppUiTheme.light().colorScheme;
    report.report(
      'movie',
      paletteKey(null, 'movie', 'Primary', 'poster'),
      blue,
    );
    await _settle(tester);
    // 海报不是详情取色来源;只有规范 backdrop 才能染表面。
    expect(scheme.surface, base.surface);
    report.report('movie', paletteKey(null, 'movie', 'Backdrop', 'back'), red);
    await _settle(tester);
    expect(scheme.surface, isNot(base.surface));
    expect(scheme.primaryContainer, base.primaryContainer);
    expect(scheme.primary, base.primary);
  });

  testWidgets('home overlay and detail share the backdrop mood hue', (
    tester,
  ) async {
    ContentTheme.debugClear();
    final red = (await tester.runAsync(
      () => _solidPng(const Color(0xffff3b30)),
    ))!;
    final key = paletteKey(null, 'movie', 'Backdrop', 'shared');
    late ArtworkColorScope report;
    late AppColorScheme scheme;
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: ContentTheme(
          item: const MediaItem(
            id: 'movie',
            name: '',
            type: 'Movie',
            backdropImageTag: 'shared',
            primaryImageTag: 'poster',
          ),
          child: Builder(
            builder: (context) {
              report = ArtworkColorScope.maybeOf(context)!;
              scheme = AppUiTheme.of(context).colorScheme;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    report.report('movie', key, red);
    await _settle(tester);
    expect(scheme.surface, isNot(AppUiTheme.dark().colorScheme.surface));
    final detailMood = ArtworkMoodCache.instance.peek(
      artworkMoodKey(key, Brightness.dark),
    );
    expect(detailMood, isNotNull);
    expect(detailMood!.neutral, isFalse);

    // 首页用同一 key 的同一份 mood 缓存渲染覆盖层。
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: HeroPaletteOverlay(
          paletteKey: key,
          child: _Reporter(paletteKey: key, bytes: red),
        ),
      ),
    );
    await _settle(tester);
    final container = tester.widget<AnimatedContainer>(
      find.byKey(HeroPaletteOverlay.overlayKey),
    );
    final gradient =
        (container.decoration! as BoxDecoration).gradient! as LinearGradient;
    final first = gradient.colors.first;
    expect(first.a, greaterThan(0));
    expect(
      _hueDistance(
        HSLColor.fromColor(first).hue,
        HSLColor.fromColor(detailMood.seed).hue,
      ),
      lessThanOrEqualTo(15),
    );
    // 固定品牌天青不参与色相一致性的判定。
    expect(
      _hueDistance(
        HSLColor.fromColor(first).hue,
        HSLColor.fromColor(AppBrand.cyan).hue,
      ),
      greaterThan(15),
    );
  });

  testWidgets('detail keeps a neutral brand surface without artwork', (
    tester,
  ) async {
    ContentTheme.debugClear();
    late AppColorScheme scheme;
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: ContentTheme(
          item: null,
          child: Builder(
            builder: (context) {
              scheme = AppUiTheme.of(context).colorScheme;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(scheme.surface, AppUiTheme.dark().colorScheme.surface);
  });
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

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}
