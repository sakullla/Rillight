import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/artwork_color_scope.dart';
import 'package:rillight/app/artwork_theme_source.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/app/ui/ui.dart' as app_ui;
import 'package:rillight/media_image/media_image.dart';

void main() {
  for (final theme in [app_ui.AppUiTheme.light(), app_ui.AppUiTheme.dark()]) {
    testWidgets(
      'neutral Cupertino artwork palette preserves contrast in ${theme.brightness}',
      (tester) async {
        final base = theme.colorScheme;
        final schemes = await tester.runAsync(
          () async => [
            for (final color in [
              const Color(0xffff3b30),
              const Color(0xff007aff),
              const Color(0xffff00ff),
              const Color(0xffffffff),
              const Color(0xff000000),
            ])
              await app_ui.contentPaletteFromBytes(
                await _solidPng(color),
                base,
              ),
            await app_ui.contentPaletteFromBytes(Uint8List(0), base),
          ],
        );
        // 剧照只染 7 个表面;主色与容器保持品牌色。
        expect(schemes!.take(3).map((s) => s.surface).toSet(), hasLength(3));
        for (final scheme in schemes) {
          expect(scheme.primary, base.primary);
          expect(scheme.primaryContainer, base.primaryContainer);
          expect(scheme.error, base.error);
          expect(scheme.brightness, base.brightness);
          expect(_contrast(scheme.onPrimary, scheme.primary), greaterThan(4.5));
          expect(_contrast(scheme.onSurface, scheme.surface), greaterThan(4.5));
          expect(
            _contrast(scheme.onSurfaceVariant, scheme.surface),
            greaterThan(4.5),
          );
        }
        for (final scheme in schemes.skip(3)) {
          expect(scheme, same(base));
        }
      },
    );
  }

  testWidgets('episodes sharing a backdrop keep their resolved palette', (
    tester,
  ) async {
    ContentTheme.debugClear();
    final bytes = (await tester.runAsync(
      () => _solidPng(const Color(0xffff3b30)),
    ))!;
    late ArtworkColorScope report;
    late AppColorScheme scheme;
    Widget page(String episode, String backdrop) => CupertinoTestApp(
      theme: AppUiTheme.dark(),
      home: ContentTheme(
        item: MediaItem(
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
            scheme = AppUiTheme.of(context).colorScheme;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(page('episode-1', 'shared'));
    report.report(
      'episode-1',
      paletteKey(null, 'series', 'Backdrop', 'shared'),
      bytes,
    );
    await _settlePalette(tester);
    final resolved = scheme;
    expect(resolved.surface, isNot(AppUiTheme.dark().colorScheme.surface));
    expect(
      resolved.primaryContainer,
      AppUiTheme.dark().colorScheme.primaryContainer,
    );
    await tester.pumpWidget(page('episode-2', 'shared'));
    expect(scheme.surface, resolved.surface);
    await tester.pumpWidget(page('episode-2', 'replacement'));
    expect(scheme, AppUiTheme.dark().colorScheme);
  });

  testWidgets('artwork palette waits for scrolling to become idle', (
    tester,
  ) async {
    ContentTheme.debugClear();
    addTearDown(MediaImage.debugResetCacheConfiguration);
    final red = (await tester.runAsync(
      () => _solidPng(const Color(0xffff3b30)),
    ))!;
    late ArtworkColorScope report;
    late AppColorScheme scheme;
    var builds = 0;
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: ContentTheme(
          item: const MediaItem(
            id: 'poster',
            name: '',
            type: 'Movie',
            backdropImageTag: 'poster-tag',
          ),
          child: Builder(
            builder: (context) {
              builds++;
              report = ArtworkColorScope.maybeOf(context)!;
              scheme = AppUiTheme.of(context).colorScheme;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final before = builds;
    MediaImageCache.instance.markScrollActivity();
    report.report(
      'poster',
      paletteKey(null, 'poster', 'Backdrop', 'poster-tag'),
      red,
    );
    await tester.pump(const Duration(milliseconds: 20));
    expect(scheme, AppUiTheme.dark().colorScheme);
    expect(builds, before);
    await _settlePalette(tester);
    expect(scheme.surface, isNot(AppUiTheme.dark().colorScheme.surface));
    expect(
      scheme.primaryContainer,
      AppUiTheme.dark().colorScheme.primaryContainer,
    );
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
      late AppColorScheme scheme;
      var taps = 0;
      await tester.pumpWidget(
        CupertinoTestApp(
          theme: brightness == Brightness.dark
              ? AppUiTheme.dark()
              : AppUiTheme.light(),
          home: CupertinoPageScaffold(
            child: ContentTheme(
              item: const MediaItem(
                id: 'genre',
                name: '',
                type: 'Movie',
                backdropImageTag: 'genre-tag',
              ),
              child: Builder(
                builder: (context) {
                  report = ArtworkColorScope.maybeOf(context)!;
                  scheme = AppUiTheme.of(context).colorScheme;
                  return Wrap(
                    children: [
                      AppChoiceChip(
                        focusNode: focus,
                        label: const Text('动作冒险'),
                        onSelected: (_) => taps++,
                      ),
                      AppChoiceChip(
                        label: const Text('已选择'),
                        selected: true,
                        onSelected: (_) {},
                      ),
                      const AppChoiceChip(label: Text('不可用')),
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
                  .widget<AnimatedContainer>(
                    find
                        .descendant(
                          of: find.widgetWithText(AppChoiceChip, label),
                          matching: find.byType(AnimatedContainer),
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
      for (final color in [
        const Color(0xffff3b30),
        const Color(0xff007aff),
        const Color(0xff34c759),
      ]) {
        final bytes = (await tester.runAsync(() => _solidPng(color)))!;
        report.report(
          'genre',
          paletteKey(null, 'genre', 'Backdrop', 'genre-tag'),
          bytes,
        );
        await _settlePalette(tester);
        final background = chipDecoration('动作冒险').color!;
        expect(background, scheme.surfaceContainerHigh);
        expect(labelColor('动作冒险'), scheme.onSurface);
        expect(_contrast(labelColor('动作冒险'), background), greaterThan(4.5));
        // 选中统一用实底主色表达。
        expect(chipDecoration('已选择').color, scheme.primary);
        expect(labelColor('已选择'), scheme.onPrimary);
        expect(chipDecoration('不可用').color, scheme.surfaceContainerHigh);
        focus.requestFocus();
        await settle(tester);
        expect(
          (chipDecoration('动作冒险').shape as OutlinedBorder).side,
          BorderSide(color: scheme.primary, width: 2),
        );
        focus.unfocus();
        await settle(tester);
      }
      await tester.tap(find.text('动作冒险'));
      expect(taps, 1);
    });

    for (final seed in [
      const Color(0xffff3b30),
      const Color(0xffffcc00),
      const Color(0xff000000),
    ]) {
      test('artwork $seed uses paired $brightness content tones', () {
        final base = brightness == Brightness.dark
            ? AppUiTheme.dark().colorScheme
            : AppUiTheme.light().colorScheme;
        final composed = composeContentPalette(base, seed);
        expect(
          _contrast(composed.onPrimary, composed.primary),
          greaterThan(4.5),
        );
        expect(composed.onSurface, base.onSurface);
        expect(composed.onSurfaceVariant, base.onSurfaceVariant);
        expect(composed.primary, base.primary);
        expect(composed.primaryContainer, base.primaryContainer);
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
          ? AppUiTheme.dark().colorScheme
          : AppUiTheme.light().colorScheme;
      final schemes = await tester.runAsync(() async {
        final output = <AppColorScheme>[];
        for (final color in [
          const Color(0xffff3b30),
          const Color(0xff007aff),
          const Color(0xffff00ff),
          const Color(0xffffffff),
          const Color(0xff000000),
          const Color(0xff808080),
        ]) {
          output.add(
            await contentPaletteFromBytes(await _solidPng(color), base),
          );
        }
        return output;
      });
      expect(schemes!.take(3).map((s) => s.surface).toSet(), hasLength(3));
      expect(schemes.first.brightness, brightness);
      expect(schemes.first.primaryContainer, base.primaryContainer);
      expect(schemes.first.primary, base.primary);
      expect(schemes.first.error, base.error);
      expect(schemes.first.surfaceTint, const Color(0x00000000));
      expect(
        schemes.first.onSurface.computeLuminance(),
        brightness == Brightness.dark ? greaterThan(.5) : lessThan(.1),
      );
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
      late AppColorScheme leftScheme, rightScheme, globalScheme;
      final red = (await tester.runAsync(
        () => _solidPng(const Color(0xffff3b30)),
      ))!;
      final blue = (await tester.runAsync(
        () => _solidPng(const Color(0xff007aff)),
      ))!;
      Widget app(String id, Brightness brightness) => CupertinoTestApp(
        theme: brightness == Brightness.dark
            ? AppUiTheme.dark()
            : AppUiTheme.light(),
        home: Builder(
          builder: (context) {
            globalScheme = AppUiTheme.of(context).colorScheme;
            return Row(
              children: [
                Expanded(
                  child: ContentTheme(
                    item: MediaItem(
                      id: id,
                      name: id,
                      type: 'Movie',
                      backdropImageTag: 'tag',
                    ),
                    child: Builder(
                      builder: (context) {
                        leftReport = ArtworkColorScope.maybeOf(context)!;
                        leftScheme = AppUiTheme.of(context).colorScheme;
                        return const SizedBox(height: 80);
                      },
                    ),
                  ),
                ),
                Expanded(
                  child: ContentTheme(
                    item: const MediaItem(
                      id: 'right',
                      name: '',
                      type: 'Movie',
                      backdropImageTag: 'tag',
                    ),
                    child: Builder(
                      builder: (context) {
                        rightReport = ArtworkColorScope.maybeOf(context)!;
                        rightScheme = AppUiTheme.of(context).colorScheme;
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
      String key(String id, [String tag = 'tag']) =>
          paletteKey(null, id, 'Backdrop', tag);
      await tester.pumpWidget(app('old', Brightness.dark));
      final stale = leftReport;
      stale.report('old', key('old', 'late-tag'), blue);
      await tester.pump();
      await tester.pumpWidget(app('new', Brightness.dark));
      stale.report('old', key('old'), red);
      rightReport.report('right', key('right'), blue);
      leftReport.report('new', key('new'), red);
      await _settlePalette(tester);
      expect(leftScheme.surface, isNot(rightScheme.surface));
      expect(leftScheme.surface, isNot(globalScheme.surface));
      expect(globalScheme, AppUiTheme.dark().colorScheme);
      final oldLightCallback = leftReport;
      await tester.pumpWidget(app('new', Brightness.light));
      expect(leftScheme.brightness, Brightness.light);
      // Mood survives a brightness switch; only the derived surfaces change.
      expect(leftScheme.surface, isNot(AppUiTheme.light().colorScheme.surface));
      oldLightCallback.report('new', key('new'), blue);
      leftReport.report('new', key('new', 'new-tag'), red);
      await _settlePalette(tester);
      expect(leftScheme.brightness, Brightness.light);
      expect(
        _contrast(leftScheme.onSurface, leftScheme.surface),
        greaterThan(4.5),
      );
    },
  );
}

Future<Uint8List> _solidPng(Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 32, 32), Paint()..color = color);
  final image = await recorder.endRecording().toImage(32, 32);
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
