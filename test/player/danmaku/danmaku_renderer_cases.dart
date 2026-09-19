import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/danmaku/danmaku_glyph_cache.dart';
import 'package:rillight/player/danmaku/danmaku_layout.dart';
import 'package:rillight/player/danmaku/danmaku_renderer.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/player_settings.dart';

const viewport = Size(800, 400);

DanmakuComment comment(
  int cid,
  double time, {
  int mode = 1,
  int color = 16711680,
  String? text,
}) => DanmakuComment(
  cid: cid,
  time: time,
  mode: mode,
  color: color,
  text: text ?? '弹幕$cid',
);

int fontPxFor(Size size, {double fontScale = 1}) {
  final viewScale = (size.height / kDanmakuViewportReferenceHeight).clamp(
    kDanmakuViewportScaleMin,
    kDanmakuViewportScaleMax,
  );
  return (kDanmakuBaseFontSize * fontScale * viewScale).round();
}

DanmakuController controllerWith(List<DanmakuComment> comments) {
  final controller = DanmakuController(
    settingsStore: MemoryPlayerSettingsStore(),
    textMeasurer: (text, fontSize) => text.length * fontSize * 0.6,
  );
  controller.layout.comments = comments;
  return controller;
}

Future<void> pumpDanmaku(
  WidgetTester tester,
  DanmakuController controller,
) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: viewport.width,
        height: viewport.height,
        child: DanmakuView(controller: controller),
      ),
    ),
  );
}

Future<DanmakuViewState> warmup(
  WidgetTester tester,
  DanmakuController controller,
) async {
  await tester.pump();
  controller.glyphCache.debugFinishPrepareSync();
  await tester.pump();
  return tester.state<DanmakuViewState>(find.byType(DanmakuView));
}

Future<void> pumpFrames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets('renders comments driven by the ticker while playing', (
    tester,
  ) async {
    final controller = controllerWith([comment(1, 0), comment(2, 0.5)]);
    controller.updatePosition(Duration.zero, playing: true, rate: 1);
    await pumpDanmaku(tester, controller);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.layout.activeCount, greaterThan(0));
    await tester.pump(const Duration(seconds: 5));
    expect(controller.layout.activeCount, greaterThan(0));
  });

  testWidgets('paused playback keeps the last frames without ticking', (
    tester,
  ) async {
    final controller = controllerWith([comment(1, 0)]);
    controller.updatePosition(
      const Duration(seconds: 2),
      playing: true,
      rate: 1,
    );
    await pumpDanmaku(tester, controller);
    await warmup(tester, controller);
    controller.updatePosition(
      const Duration(seconds: 2),
      playing: false,
      rate: 1,
    );
    await tester.pump();
    final state = tester.state<DanmakuViewState>(find.byType(DanmakuView));
    expect(state.debugTickerActive, isFalse);
    expect(controller.layout.activeEntries, isNotEmpty);
    final pausedLeft = controller.layout.activeEntries.single.left;
    await tester.pump(const Duration(seconds: 30));
    expect(state.debugTickerActive, isFalse);
    expect(controller.layout.activeEntries, isNotEmpty);
    expect(
      controller.layout.activeEntries.single.left,
      closeTo(pausedLeft, 0.01),
    );
  });

  testWidgets('no comments mounts without errors or progress', (tester) async {
    final controller = controllerWith(const []);
    controller.updatePosition(Duration.zero, playing: true, rate: 1);
    await pumpDanmaku(tester, controller);
    await tester.pump(const Duration(seconds: 5));
    expect(controller.layout.activeCount, 0);
    expect(controller.hasComments, isFalse);
  });

  testWidgets('paused then resumed playback restarts the ticker', (
    tester,
  ) async {
    final controller = controllerWith([comment(1, 0)]);
    controller.updatePosition(
      const Duration(seconds: 2),
      playing: true,
      rate: 1,
    );
    await pumpDanmaku(tester, controller);
    await warmup(tester, controller);
    final state = tester.state<DanmakuViewState>(find.byType(DanmakuView));
    expect(state.debugTickerActive, isTrue);
    expect(controller.layout.activeEntries, isNotEmpty);

    controller.updatePosition(
      const Duration(seconds: 2),
      playing: false,
      rate: 1,
    );
    await tester.pump();
    expect(state.debugTickerActive, isFalse);
    final pausedLeft = controller.layout.activeEntries.single.left;
    await tester.pump(const Duration(seconds: 2));
    expect(state.debugTickerActive, isFalse);
    expect(
      controller.layout.activeEntries.single.left,
      closeTo(pausedLeft, 0.01),
    );

    controller.updatePosition(
      const Duration(seconds: 2),
      playing: true,
      rate: 1,
    );
    await tester.pump();
    expect(state.debugTickerActive, isTrue);

    controller.updatePosition(
      const Duration(seconds: 3),
      playing: true,
      rate: 1,
    );
    await tester.pump();
    expect(state.debugTickerActive, isTrue);
    expect(controller.layout.activeEntries, isNotEmpty);
    expect(
      controller.layout.activeEntries.single.left,
      lessThan(pausedLeft - 0.5),
    );
  });

  testWidgets(
    'after warmup ticker frames do not sync-layout and pause freezes',
    (tester) async {
      final controller = controllerWith([comment(1, 0), comment(2, 0.2)]);
      controller.updatePosition(Duration.zero, playing: true, rate: 1);
      await pumpDanmaku(tester, controller);
      final state = await warmup(tester, controller);
      state.debugLayoutCallsDuringTick = 0;
      await pumpFrames(tester, 60);
      expect(state.debugLayoutCallsDuringTick, 0);

      controller.updatePosition(Duration.zero, playing: false, rate: 1);
      await tester.pump();
      expect(state.debugTickerActive, isFalse);
      final frozen = [
        for (final item in controller.layout.activeEntries) item.left,
      ];
      await tester.pump(const Duration(seconds: 2));
      expect(state.debugTickerActive, isFalse);
      expect(controller.layout.activeEntries.length, frozen.length);
      for (var i = 0; i < frozen.length; i++) {
        expect(
          controller.layout.activeEntries[i].left,
          closeTo(frozen[i], 0.01),
        );
      }
    },
  );

  testWidgets('scroll-only frames do not repaint the fixed layer', (
    tester,
  ) async {
    final controller = controllerWith([comment(1, 0)]);
    controller.updatePosition(Duration.zero, playing: true, rate: 1);
    await pumpDanmaku(tester, controller);
    final state = await warmup(tester, controller);
    final afterInit = state.debugFixedLayerPaintCount;
    expect(afterInit, lessThanOrEqualTo(1));
    await pumpFrames(tester, 60);
    expect(state.debugFixedLayerPaintCount, afterInit);

    controller.layout.comments = [
      comment(1, 0),
      comment(2, 0, mode: 5, text: '顶部'),
    ];
    controller.layout.reset();
    controller.notifyListeners();
    await tester.pump();
    expect(state.debugFixedLayerPaintCount, afterInit + 1);
  });

  testWidgets('episode and style changes rebuild the glyph cache', (
    tester,
  ) async {
    final controller = controllerWith([
      comment(1, 0, text: 'same'),
      comment(2, 0, text: 'same'),
    ]);
    controller.updatePosition(Duration.zero, playing: true, rate: 1);
    await pumpDanmaku(tester, controller);
    final state = await warmup(tester, controller);
    expect(state.debugGlyphCacheSize, 1);

    controller.layout.comments = [comment(9, 0, text: 'next-ep')];
    controller.layout.reset();
    controller.notifyListeners();
    await tester.pump();
    controller.glyphCache.debugFinishPrepareSync();
    await tester.pump();
    expect(state.debugGlyphCacheSize, 1);

    await controller.setDisplay(
      const DanmakuDisplaySettings(opacity: 0.4, fontScale: 1.5),
    );
    await tester.pump();
    controller.glyphCache.debugFinishPrepareSync();
    await tester.pump();
    expect(state.debugGlyphCacheSize, greaterThan(0));
    expect(controller.layout.activeEntries, isNotEmpty);
    expect(controller.layout.activeEntries.single.opacity, closeTo(0.4, 0.01));
    expect(
      controller.layout.activeEntries.single.fontSize,
      fontPxFor(viewport, fontScale: 1.5).toDouble(),
    );

    final sizeAfterFont = state.debugGlyphCacheSize;
    await controller.setDisplay(
      const DanmakuDisplaySettings(
        opacity: 0.4,
        fontScale: 1.5,
        outline: false,
      ),
    );
    await tester.pump();
    controller.glyphCache.debugFinishPrepareSync();
    await tester.pump();
    expect(state.debugGlyphCacheSize, sizeAfterFont);

    await controller.setDisplay(
      const DanmakuDisplaySettings(
        opacity: 0.4,
        fontScale: 1.5,
        outline: false,
        colorful: false,
      ),
    );
    await tester.pump();
    controller.glyphCache.debugFinishPrepareSync();
    await tester.pump();
    expect(state.debugGlyphCacheSize, greaterThan(0));
  });

  testWidgets(
    'colorful false uses white paragraphs; outline false draws once',
    (tester) async {
      final controller = controllerWith([comment(1, 0)]);
      controller.updatePosition(Duration.zero, playing: true, rate: 1);
      await pumpDanmaku(tester, controller);
      await warmup(tester, controller);

      await controller.setDisplay(
        const DanmakuDisplaySettings(colorful: false),
      );
      await tester.pump();
      controller.glyphCache.debugFinishPrepareSync();
      await tester.pump();
      final white = controller.glyphCache.get(
        const DanmakuGlyphKey('弹幕1', kDanmakuGlyphWhiteRgb),
      );
      final alpha = (controller.display.opacity * 0xFF).round().clamp(0, 255);
      expect(white.fillColor.toARGB32(), (alpha << 24) | kDanmakuGlyphWhiteRgb);
      expect(white.stroke, isNotNull);

      await controller.setDisplay(
        const DanmakuDisplaySettings(colorful: false, outline: false),
      );
      await tester.pump();
      controller.glyphCache.debugFinishPrepareSync();
      await tester.pump();
      final state = tester.state<DanmakuViewState>(find.byType(DanmakuView));
      final plain = controller.glyphCache.get(
        const DanmakuGlyphKey('弹幕1', kDanmakuGlyphWhiteRgb),
      );
      expect(plain.stroke, isNull);
      expect(controller.layout.activeCount, greaterThan(0));
      expect(state.debugLastDrawParagraphCount, controller.layout.activeCount);
    },
  );
}
