import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';

import 'package:flutter/gestures.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/desktop_gestures.dart';

void main() {
  testWidgets('trackpad pinch enters and leaves fullscreen only on release', (
    tester,
  ) async {
    final fullscreen = <bool>[];
    var seeks = 0;
    await tester.pumpWidget(
      CupertinoTestApp(
        home: DesktopPlaybackGestures(
          position: Duration.zero,
          duration: const Duration(minutes: 2),
          volume: 80,
          isFullScreen: false,
          onSeek: (_) async => seeks++,
          onVolume: (_) async {},
          onFullScreen: (value) async => fullscreen.add(value),
          child: const SizedBox.expand(),
        ),
      ),
    );
    for (final scale in [1.3, .7]) {
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await gesture.panZoomStart(const Offset(100, 100));
      await gesture.panZoomUpdate(const Offset(100, 100), scale: scale);
      final count = fullscreen.length;
      await tester.pump();
      expect(fullscreen.length, count);
      await gesture.panZoomEnd();
    }
    expect(fullscreen, [true, false]);
    expect(seeks, 0);
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));
  testWidgets('trackpad navigation commits once after a deliberate swipe', (
    tester,
  ) async {
    var backs = 0;
    await tester.pumpWidget(
      CupertinoTestApp(
        home: DesktopNavigationGestures(
          onBack: () => backs++,
          child: const SizedBox.expand(),
        ),
      ),
    );
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(const Offset(100, 100));
    await gesture.panZoomUpdate(
      const Offset(100, 100),
      pan: const Offset(30, 0),
    );
    await gesture.panZoomUpdate(
      const Offset(100, 100),
      pan: const Offset(160, 0),
    );
    expect(backs, 0);
    await gesture.panZoomEnd();
    expect(backs, 1);
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets('a horizontal shelf consumes its gesture before navigation', (
    tester,
  ) async {
    var forwards = 0;
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      CupertinoTestApp(
        home: DesktopNavigationGestures(
          onForward: () => forwards++,
          child: ListView(
            controller: scroll,
            scrollDirection: Axis.horizontal,
            children: const [SizedBox(width: 2000, height: 300)],
          ),
        ),
      ),
    );
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(const Offset(200, 100));
    await gesture.panZoomUpdate(
      const Offset(200, 100),
      pan: const Offset(-30, 0),
    );
    await gesture.panZoomUpdate(
      const Offset(200, 100),
      pan: const Offset(-160, 0),
    );
    await gesture.panZoomEnd();
    expect(scroll.offset, greaterThan(0));
    expect(forwards, 0);
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets('playback drag previews without repeatedly seeking the core', (
    tester,
  ) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(
      CupertinoTestApp(
        home: DesktopPlaybackGestures(
          position: const Duration(seconds: 50),
          duration: const Duration(minutes: 2),
          volume: 80,
          isFullScreen: false,
          onSeek: (value) async => seeks.add(value),
          onVolume: (_) async {},
          onFullScreen: (_) async {},
          child: const SizedBox.expand(),
        ),
      ),
    );
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(const Offset(100, 100));
    await gesture.panZoomUpdate(
      const Offset(100, 100),
      pan: const Offset(30, 0),
    );
    await gesture.panZoomUpdate(
      const Offset(100, 100),
      pan: const Offset(150, 0),
    );
    await tester.pump();
    expect(seeks, isEmpty);
    await gesture.panZoomEnd();
    expect(seeks, hasLength(1));
    expect(seeks.single, greaterThan(const Duration(seconds: 50)));
    expect(seeks.single, lessThan(const Duration(seconds: 70)));
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets('vertical gestures change volume without seeking', (
    tester,
  ) async {
    final volumes = <int>[];
    var seeks = 0;
    await tester.pumpWidget(
      CupertinoTestApp(
        home: DesktopPlaybackGestures(
          position: Duration.zero,
          duration: const Duration(minutes: 2),
          volume: 80,
          isFullScreen: false,
          onSeek: (_) async => seeks++,
          onVolume: (value) async => volumes.add(value),
          onFullScreen: (_) async {},
          child: const SizedBox.expand(),
        ),
      ),
    );
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(const Offset(100, 100));
    await gesture.panZoomUpdate(
      const Offset(100, 100),
      pan: const Offset(0, 30),
    );
    await gesture.panZoomUpdate(
      const Offset(100, 100),
      pan: const Offset(0, 110),
    );
    await gesture.panZoomEnd();
    expect(seeks, 0);
    expect(volumes.single, lessThan(80));
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));

  /// 鼠标单击/双击：桌面真实点击以 mouse 设备上报(tester.tap 默认 touch)。
  Future<void> mouseClick(WidgetTester tester, Offset position) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.down(position);
    await gesture.up();
    await gesture.removePointer();
  }

  Future<void> mouseDoubleClick(WidgetTester tester, Offset position) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.down(position);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.down(position);
    await gesture.up();
    await gesture.removePointer();
  }

  testWidgets(
    'double-click toggles fullscreen on every desktop platform',
    (tester) async {
      final fullscreen = <bool>[];
      Widget build({required bool isFullScreen}) => CupertinoTestApp(
        home: DesktopPlaybackGestures(
          position: Duration.zero,
          duration: const Duration(minutes: 2),
          volume: 80,
          isFullScreen: isFullScreen,
          onSeek: (_) async {},
          onVolume: (_) async {},
          onFullScreen: (value) async => fullscreen.add(value),
          child: const SizedBox.expand(),
        ),
      );
      const center = Offset(100, 100);
      await tester.pumpWidget(build(isFullScreen: false));
      // 单击不动全屏;等双击窗口(300ms)彻底结束再做下一组。
      await mouseClick(tester, center);
      await tester.pump(const Duration(milliseconds: 400));
      expect(fullscreen, isEmpty);
      // 鼠标双击进入全屏。
      await mouseDoubleClick(tester, center);
      await tester.pump(const Duration(milliseconds: 400));
      expect(fullscreen, [true]);
      // 按窗口真实状态重建后，双击退出全屏。
      await tester.pumpWidget(build(isFullScreen: true));
      await mouseDoubleClick(tester, center);
      await tester.pump(const Duration(milliseconds: 400));
      expect(fullscreen, [true, false]);
      // 单击同样不动全屏。
      await mouseClick(tester, center);
      await tester.pump(const Duration(milliseconds: 400));
      expect(fullscreen, [true, false]);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    }),
  );

  testWidgets('macOS mouse double-click works alongside the trackpad layer', (
    tester,
  ) async {
    // 真实 macOS 上触控板双按以上报 mouse 点击事件送达(触控板 kind 只用于
    // 捏合/滑动),所以这里用鼠标事件覆盖 macOS 路径:与捏合手势层共存不冲突。
    final fullscreen = <bool>[];
    await tester.pumpWidget(
      CupertinoTestApp(
        home: DesktopPlaybackGestures(
          position: Duration.zero,
          duration: const Duration(minutes: 2),
          volume: 80,
          isFullScreen: false,
          onSeek: (_) async {},
          onVolume: (_) async {},
          onFullScreen: (value) async => fullscreen.add(value),
          child: const SizedBox.expand(),
        ),
      ),
    );
    await mouseDoubleClick(tester, const Offset(100, 100));
    await tester.pump(const Duration(milliseconds: 400));
    expect(fullscreen, [true]);
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets(
    'double-click is ignored while gestures are disabled',
    (tester) async {
      final fullscreen = <bool>[];
      await tester.pumpWidget(
        CupertinoTestApp(
          home: DesktopPlaybackGestures(
            position: Duration.zero,
            duration: const Duration(minutes: 2),
            volume: 80,
            isFullScreen: false,
            enabled: false,
            onSeek: (_) async {},
            onVolume: (_) async {},
            onFullScreen: (value) async => fullscreen.add(value),
            child: const SizedBox.expand(),
          ),
        ),
      );
      await mouseDoubleClick(tester, const Offset(100, 100));
      await tester.pump(const Duration(milliseconds: 400));
      expect(fullscreen, isEmpty);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );
}
