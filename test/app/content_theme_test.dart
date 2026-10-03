import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/artwork_color_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/media_image/media_image.dart';

void main() {
  testWidgets('episodes sharing a backdrop keep their resolved palette', (
    tester,
  ) async {
    ContentTheme.debugClear();
    final bytes = (await tester.runAsync(() => _solidPng(Colors.red)))!;
    late ArtworkColorScope report;
    late ColorScheme scheme;
    Widget page(String episode, String backdrop) => MaterialApp(
      theme: AppTheme.dark(),
      home: ContentTheme(
        item: EmbyItem(
          id: episode,
          name: '',
          type: 'Episode',
          parentBackdropItemId: 'series',
          parentBackdropImageTag: backdrop,
        ),
        preferParentBackdrop: true,
        child: Builder(
          builder: (context) {
            report = ArtworkColorScope.maybeOf(context)!;
            scheme = Theme.of(context).colorScheme;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(page('episode-1', 'shared'));
    report.report('episode-1', 'shared-backdrop', bytes);
    await _settlePalette(tester);
    final resolved = scheme;
    expect(resolved.primary, isNot(AppTheme.dark().colorScheme.primary));
    await tester.pumpWidget(page('episode-2', 'shared'));
    expect(scheme, resolved);
    await tester.pumpWidget(page('episode-2', 'replacement'));
    expect(scheme, AppTheme.dark().colorScheme);
  });

  testWidgets('artwork palette waits for scrolling to become idle', (
    tester,
  ) async {
    ContentTheme.debugClear();
    addTearDown(MediaImage.debugResetCacheConfiguration);
    final red = (await tester.runAsync(() => _solidPng(Colors.red)))!;
    late ArtworkColorScope report;
    late ColorScheme scheme;
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: ContentTheme(
          item: const EmbyItem(id: 'poster', name: '', type: 'Movie'),
          child: Builder(
            builder: (context) {
              builds++;
              report = ArtworkColorScope.maybeOf(context)!;
              scheme = Theme.of(context).colorScheme;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final before = builds;
    MediaImageCache.instance.markScrollActivity();
    report.report('poster', 'scroll-palette', red);
    await tester.pump(const Duration(milliseconds: 20));
    expect(scheme, AppTheme.dark().colorScheme);
    expect(builds, before);
    await _settlePalette(tester);
    expect(scheme.primary, isNot(AppTheme.dark().colorScheme.primary));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final brightness in Brightness.values) {
    testWidgets('chips follow artwork and preserve focus in $brightness', (
      tester,
    ) async {
      ContentTheme.debugClear();
      final focus = FocusNode();
      addTearDown(focus.dispose);
      late ArtworkColorScope report;
      late ColorScheme scheme;
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: brightness == Brightness.dark
              ? AppTheme.dark()
              : AppTheme.light(),
          home: Scaffold(
            body: ContentTheme(
              item: const EmbyItem(id: 'genre', name: '', type: 'Movie'),
              child: Builder(
                builder: (context) {
                  report = ArtworkColorScope.maybeOf(context)!;
                  scheme = Theme.of(context).colorScheme;
                  return Wrap(
                    children: [
                      ActionChip(
                        focusNode: focus,
                        label: const Text('动作冒险'),
                        onPressed: () => taps++,
                      ),
                      ChoiceChip(
                        label: const Text('已选择'),
                        selected: true,
                        onSelected: (_) {},
                      ),
                      const ActionChip(label: Text('不可用')),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      ShapeDecoration chipDecoration(String label) =>
          tester
                  .widget<Ink>(
                    find
                        .descendant(
                          of: find.widgetWithText(RawChip, label),
                          matching: find.byType(Ink),
                        )
                        .first,
                  )
                  .decoration!
              as ShapeDecoration;
      Color labelColor(String label) => tester
          .widget<RichText>(
            find.descendant(
              of: find.text(label),
              matching: find.byType(RichText),
            ),
          )
          .text
          .style!
          .color!;
      for (final color in [Colors.red, Colors.blue, Colors.green]) {
        final bytes = (await tester.runAsync(() => _solidPng(color)))!;
        report.report('genre', 'genre-$brightness-$color', bytes);
        await _settlePalette(tester);
        final background = chipDecoration('动作冒险').color!;
        expect(background, scheme.surfaceContainerHigh);
        expect(labelColor('动作冒险'), scheme.onSurface);
        expect(_contrast(labelColor('动作冒险'), background), greaterThan(4.5));
        expect(chipDecoration('已选择').color, scheme.primaryContainer);
        expect(labelColor('已选择'), scheme.onPrimaryContainer);
        expect(chipDecoration('不可用').color, scheme.surfaceContainer);
        focus.requestFocus();
        await tester.pumpAndSettle();
        expect(
          (chipDecoration('动作冒险').shape as OutlinedBorder).side,
          BorderSide(color: scheme.primary, width: 2),
        );
        focus.unfocus();
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('动作冒险'));
      expect(taps, 1);
    });

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
