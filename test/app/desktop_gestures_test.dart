import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/desktop_gestures.dart';

void main() {
  testWidgets('trackpad pinch enters and leaves fullscreen only on release', (
    tester,
  ) async {
    final fullscreen = <bool>[];
    var seeks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopPlaybackGestures(
          position: Duration.zero,
          duration: const Duration(minutes: 2),
          volume: 80,
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
      MaterialApp(
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
      MaterialApp(
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
      MaterialApp(
        home: DesktopPlaybackGestures(
          position: const Duration(seconds: 50),
          duration: const Duration(minutes: 2),
          volume: 80,
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
      MaterialApp(
        home: DesktopPlaybackGestures(
          position: Duration.zero,
          duration: const Duration(minutes: 2),
          volume: 80,
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
}
