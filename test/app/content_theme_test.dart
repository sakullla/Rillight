import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/artwork_color_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/app/theme.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final seed in [Colors.red, Colors.yellow, Colors.black]) {
      test('artwork $seed uses paired $brightness content tones', () {
        final base = brightness == Brightness.dark
            ? AppTheme.dark().colorScheme
            : AppTheme.light().colorScheme;
        final artwork = ColorScheme.fromSeed(
          seedColor: seed,
          brightness: brightness,
        );
        final composed = composeContentScheme(base, artwork);
        expect(composed.primary, artwork.primary);
        expect(composed.onPrimary, artwork.onPrimary);
        expect(composed.onSurface, artwork.onSurface);
        expect(composed.onSurfaceVariant, artwork.onSurfaceVariant);
        expect(composed.error, base.error);
        final luminances = [
          composed.onSurfaceVariant.computeLuminance(),
          composed.surface.computeLuminance(),
        ]..sort();
        expect(
          (luminances.last + .05) / (luminances.first + .05),
          greaterThan(4.5),
        );
      });
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets('real colored pixels and neutral fallback in $brightness', (
      tester,
    ) async {
      final base = brightness == Brightness.dark
          ? AppTheme.dark().colorScheme
          : AppTheme.light().colorScheme;
      final schemes = await tester.runAsync(() async {
        final output = <ColorScheme>[];
        for (final color in [
          Colors.red,
          Colors.blue,
          Colors.green,
          Colors.white,
          Colors.black,
          Colors.grey,
        ]) {
          output.add(
            await contentSchemeFromBytes(await _solidPng(color), base),
          );
        }
        return output;
      });
      expect(schemes!.take(3).map((s) => s.surface).toSet(), hasLength(3));
      for (final scheme in schemes) {
        expect(_contrast(scheme.onSurface, scheme.surface), greaterThan(4.5));
        expect(
          _contrast(scheme.onSurfaceVariant, scheme.surface),
          greaterThan(4.5),
        );
        expect(_contrast(scheme.onPrimary, scheme.primary), greaterThan(4.5));
      }
      for (final scheme in schemes.skip(3)) {
        expect(scheme, base);
      }
    });
  }

  testWidgets(
    'source changes reject old palette callbacks and isolate adjacent content',
    (tester) async {
      ContentTheme.debugClear();
      late ArtworkColorScope leftReport, rightReport;
      late ColorScheme leftScheme, rightScheme, globalScheme;
      final red = (await tester.runAsync(() => _solidPng(Colors.red)))!;
      final blue = (await tester.runAsync(() => _solidPng(Colors.blue)))!;
      Widget app(String id, Brightness brightness) => MaterialApp(
        themeAnimationDuration: Duration.zero,
        theme: brightness == Brightness.dark
            ? AppTheme.dark()
            : AppTheme.light(),
        home: Builder(
          builder: (context) {
            globalScheme = Theme.of(context).colorScheme;
            return Row(
              children: [
                Expanded(
                  child: ContentTheme(
                    item: EmbyItem(id: id, name: id, type: 'Movie'),
                    child: Builder(
                      builder: (context) {
                        leftReport = ArtworkColorScope.maybeOf(context)!;
                        leftScheme = Theme.of(context).colorScheme;
                        return const SizedBox(height: 80);
                      },
                    ),
                  ),
                ),
                Expanded(
                  child: ContentTheme(
                    item: const EmbyItem(id: 'right', name: '', type: 'Movie'),
                    child: Builder(
                      builder: (context) {
                        rightReport = ArtworkColorScope.maybeOf(context)!;
                        rightScheme = Theme.of(context).colorScheme;
                        return const SizedBox(height: 80);
                      },
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );
      await tester.pumpWidget(app('old', Brightness.dark));
      final stale = leftReport;
      stale.report('old', 'account-a/old/Primary/late-tag', blue);
      await tester.pump();
      await tester.pumpWidget(app('new', Brightness.dark));
      stale.report('old', 'account-a/old/Primary/tag', red);
      rightReport.report('right', 'account-a/right/Primary/tag', blue);
      leftReport.report('new', 'account-a/new/Primary/tag', red);
      await _settlePalette(tester);
      expect(leftScheme.surface, isNot(rightScheme.surface));
      expect(leftScheme.surface, isNot(globalScheme.surface));
      expect(globalScheme, AppTheme.dark().colorScheme);
      final oldLightCallback = leftReport;
      await tester.pumpWidget(app('new', Brightness.light));
      expect(leftScheme.brightness, Brightness.light);
      expect(leftScheme.surface, AppTheme.light().colorScheme.surface);
      oldLightCallback.report('new', 'account-a/new/Primary/tag', blue);
      leftReport.report('new', 'account-a/new/Primary/new-tag', red);
      await _settlePalette(tester);
      expect(leftScheme.brightness, Brightness.light);
      expect(
        _contrast(leftScheme.onSurface, leftScheme.surface),
        greaterThan(4.5),
      );
    },
  );

  testWidgets(
    'a red image becomes a dark scheme and keeps the app error color',
    (tester) async {
      final scheme = await tester.runAsync(() async {
        final bytes = await _solidPng(const Color(0xFFE23B3B));
        final fallback = AppTheme.dark().colorScheme;
        return contentSchemeFromBytes(bytes, fallback);
      });
      final fallback = AppTheme.dark().colorScheme;

      expect(scheme, isNotNull);
      expect(scheme!.brightness, Brightness.dark);
      expect(scheme.primary.r, greaterThan(scheme.primary.b));
      expect(scheme.error, fallback.error);
      expect(scheme.onSurface.computeLuminance(), greaterThan(.5));
      expect(scheme.surfaceTint, Colors.transparent);
    },
  );

  testWidgets('a light app fallback derives a light content scheme', (
    tester,
  ) async {
    final scheme = await tester.runAsync(() async {
      final bytes = await _solidPng(const Color(0xFFE23B3B));
      final fallback = AppTheme.light().colorScheme;
      return contentSchemeFromBytes(bytes, fallback);
    });
    final fallback = AppTheme.light().colorScheme;

    expect(scheme, isNotNull);
    // 内容色亮度跟随应用主题:浅色主题下派生浅色方案。
    expect(scheme!.brightness, Brightness.light);
    expect(scheme.error, fallback.error);
    expect(scheme.onSurface.computeLuminance(), lessThan(.1));
    expect(scheme.surfaceTint, Colors.transparent);
  });
}

Future<Uint8List> _solidPng(Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 16, 16), Paint()..color = color);
  final image = await recorder.endRecording().toImage(16, 16);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

double _contrast(Color a, Color b) {
  final values = [a.computeLuminance(), b.computeLuminance()]..sort();
  return (values.last + .05) / (values.first + .05);
}

Future<void> _settlePalette(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}
