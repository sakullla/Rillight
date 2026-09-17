import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/danmaku/danmaku_renderer.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/player_settings.dart';

DanmakuComment comment(int cid, double time, {int mode = 1}) => DanmakuComment(
  cid: cid,
  time: time,
  mode: mode,
  color: 16711680,
  text: '弹幕$cid',
);

DanmakuController controllerWith(List<DanmakuComment> comments) {
  final controller = DanmakuController(
    settingsStore: MemoryPlayerSettingsStore(),
    textMeasurer: (text, fontSize) => text.length * fontSize * 0.6,
  );
  controller.layout.comments = comments;
  return controller;
}

void main() {
  testWidgets('renders comments driven by the ticker while playing', (
    tester,
  ) async {
    final controller = controllerWith([comment(1, 0), comment(2, 0.5)]);
    controller.updatePosition(Duration.zero, playing: true, rate: 1);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 800,
          height: 400,
          child: DanmakuView(controller: controller),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(controller.layout.activeCount, greaterThan(0));
    // 持续播放下仍保持活动(ticker 连续运转)。
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
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 800,
          height: 400,
          child: DanmakuView(controller: controller),
        ),
      ),
    );
    controller.updatePosition(
      const Duration(seconds: 2),
      playing: false,
      rate: 1,
    );
    final before = controller.layout.update(
      controller.estimatePosition(),
      const Size(800, 400),
    );
    await tester.pump(const Duration(seconds: 30));
    // 暂停冻结:位置不再推进,弹幕不退出。
    final after = controller.layout.update(
      controller.estimatePosition(),
      const Size(800, 400),
    );
    expect(after, isNotEmpty);
    expect(after.single.left, closeTo(before.single.left, 0.01));
  });

  testWidgets('no comments mounts without errors or progress', (tester) async {
    final controller = controllerWith(const []);
    controller.updatePosition(Duration.zero, playing: true, rate: 1);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 800,
          height: 400,
          child: DanmakuView(controller: controller),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(controller.layout.activeCount, 0);
    expect(controller.hasComments, isFalse);
  });
}
