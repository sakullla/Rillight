import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:rillight/app/artwork_color_scope.dart';
import 'package:rillight/app/artwork_theme_source.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/media_server/models.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;

void main() {
  testWidgets('artwork surfaces fade over the slow motion duration', (
    tester,
  ) async {
    ContentTheme.debugClear();
    final red = (await tester.runAsync(
      () => _solidPng(const Color(0xffff3b30)),
    ))!;
    late ArtworkColorScope report;
    late AppColorScheme scheme;
    Widget page(String tag) => CupertinoTestApp(
      theme: AppUiTheme.dark(),
      home: ContentTheme(
        item: MediaItem(
          id: 'movie',
          name: '',
          type: 'Movie',
          backdropImageTag: tag,
        ),
        child: Builder(
          builder: (context) {
            report = ArtworkColorScope.maybeOf(context)!;
            scheme = AppUiTheme.of(context).colorScheme;
            return const SizedBox();
          },
        ),
      ),
    );

    expect(ContentTheme.surfaceTransition, AppMotion.slow);
    await tester.pumpWidget(page('first'));
    final neutral = AppUiTheme.dark().colorScheme.surface;
    expect(scheme.surface, neutral);

    report.report('movie', paletteKey(null, 'movie', 'Backdrop', 'first'), red);
    await _settlePalette(tester);
    final tinted = scheme.surface;
    expect(tinted, isNot(neutral));
    // 取色未改变主色、选中态和文字。
    expect(scheme.primary, AppUiTheme.dark().colorScheme.primary);
    expect(
      scheme.primaryContainer,
      AppUiTheme.dark().colorScheme.primaryContainer,
    );

    // 换一张剧照后表面回到中性;文字与主色仍然立即是目标值。
    await tester.pumpWidget(page('second'));
    await tester.pump();
    expect(scheme.primary, AppUiTheme.dark().colorScheme.primary);
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.hasRunningAnimations, isTrue);
    expect(scheme.surface, isNot(neutral));
    expect(scheme.surface, isNot(tinted));

    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.hasRunningAnimations, isFalse);
    expect(scheme.surface, neutral);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduce motion snaps surfaces to the resolved palette', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    ContentTheme.debugClear();
    final red = (await tester.runAsync(
      () => _solidPng(const Color(0xffff3b30)),
    ))!;
    late ArtworkColorScope report;
    late AppColorScheme scheme;
    Widget page(String tag) => CupertinoTestApp(
      theme: AppUiTheme.dark(),
      home: ContentTheme(
        item: MediaItem(
          id: 'movie',
          name: '',
          type: 'Movie',
          backdropImageTag: tag,
        ),
        child: Builder(
          builder: (context) {
            report = ArtworkColorScope.maybeOf(context)!;
            scheme = AppUiTheme.of(context).colorScheme;
            return const SizedBox();
          },
        ),
      ),
    );

    await tester.pumpWidget(page('first'));
    final neutral = AppUiTheme.dark().colorScheme.surface;
    report.report('movie', paletteKey(null, 'movie', 'Backdrop', 'first'), red);
    await _settlePalette(tester);
    expect(scheme.surface, isNot(neutral));

    await tester.pumpWidget(page('second'));
    await tester.pump();
    expect(scheme.surface, neutral);
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.takeException(), isNull);
  });
}

Future<Uint8List> _solidPng(Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 32, 32), Paint()..color = color);
  final image = await recorder.endRecording().toImage(32, 32);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<void> _settlePalette(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}
