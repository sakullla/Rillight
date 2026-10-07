import 'dart:ui' show FrameTiming;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/desktop_performance_host.dart';
import 'package:rillight/app/desktop_scroll.dart';

Widget _subject(
  ScrollController controller, {
  bool reduced = false,
  TargetPlatform platform = TargetPlatform.windows,
}) => MaterialApp(
  theme: ThemeData(platform: platform),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: DesktopPerformanceHost(
      monitorTimings: true,
      child: ListView.builder(
        controller: controller,
        itemExtent: 60,
        itemCount: 100,
        itemBuilder: (context, index) => Text('$index'),
      ),
    ),
  ),
);

Future<void> _wheel(WidgetTester tester, double delta) =>
    tester.sendEventToBinding(
      PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: tester.getCenter(find.byType(ListView)),
        scrollDelta: Offset(0, delta),
      ),
    );

void main() {
  late DesktopScrollController controller;
  setUp(() => controller = DesktopScrollController());
  tearDown(() => controller.dispose());

  testWidgets('a discrete wheel tick moves over frames', (tester) async {
    await tester.pumpWidget(_subject(controller));
    await _wheel(tester, 120);
    expect(controller.offset, 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(192));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(192, 0.01));
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('wheel bursts retain the entire requested distance', (
    tester,
  ) async {
    await tester.pumpWidget(_subject(controller));
    await _wheel(tester, 120);
    await _wheel(tester, 120);
    await _wheel(tester, 120);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(576, 0.01));
  });

  testWidgets('a wheel tick responds within 32ms and finishes within 64ms', (
    tester,
  ) async {
    await tester.pumpWidget(_subject(controller));
    await _wheel(tester, 120);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(controller.offset, greaterThanOrEqualTo(192 * 0.85));
    await tester.pump(const Duration(milliseconds: 32));
    expect(controller.offset, closeTo(192, 0.01));
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('continuous wheel input has no long tail after release', (
    tester,
  ) async {
    await tester.pumpWidget(_subject(controller));
    for (var i = 0; i < 6; i++) {
      await _wheel(tester, 40);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 64));
    expect(controller.offset, closeTo(6 * 40 * 1.6, 0.01));
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('wheel events between vsyncs keep vertical scrolling moving', (
    tester,
  ) async {
    await tester.pumpWidget(_subject(controller));
    final offsets = <double>[];
    for (var i = 0; i < 8; i++) {
      await _wheel(tester, 40);
      // A real event arrives between frames; do not give each replacement
      // animation an extra zero-time frame before the next vsync.
      await tester.pump(const Duration(milliseconds: 16));
      offsets.add(controller.offset);
    }
    expect(offsets[3], greaterThan(0));
    for (var i = 2; i < offsets.length; i++) {
      expect(
        offsets[i],
        greaterThan(offsets[i - 1]),
        reason: 'Input must not restart the ticker at zero every frame',
      );
    }
    await tester.pump(const Duration(milliseconds: 64));
    expect(controller.offset, closeTo(8 * 40 * 1.6, 0.01));
  });

  testWidgets('reversing direction cancels the pending forward distance', (
    tester,
  ) async {
    await tester.pumpWidget(_subject(controller));
    controller.jumpTo(300);
    await _wheel(tester, 120);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    final reversedAt = controller.offset;
    await _wheel(tester, -120);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(reversedAt - 192, 0.01));
  });

  testWidgets('precision deltas remain immediate', (tester) async {
    await tester.pumpWidget(_subject(controller));
    await _wheel(tester, 4);
    expect(controller.offset, 4);
  });

  testWidgets('macOS keeps the platform wheel distance and response', (
    tester,
  ) async {
    await tester.pumpWidget(
      _subject(controller, platform: TargetPlatform.macOS),
    );
    await _wheel(tester, 120);
    expect(controller.offset, 120);
  });

  testWidgets('a programmatic jump interrupts wheel motion', (tester) async {
    await tester.pumpWidget(_subject(controller));
    await _wheel(tester, 120);
    await tester.pump();
    controller.jumpTo(800);
    await tester.pumpAndSettle();
    expect(controller.offset, 800);
    await _wheel(tester, 120);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(992, 0.01));
  });

  testWidgets('wheel motion clamps and stops at the content boundary', (
    tester,
  ) async {
    await tester.pumpWidget(_subject(controller));
    final end = controller.position.maxScrollExtent;
    controller.jumpTo(end - 20);
    await _wheel(tester, 120);
    await tester.pumpAndSettle();
    expect(controller.offset, end);
    await _wheel(tester, 120);
    expect(controller.offset, end);
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('system reduced motion keeps wheel ticks immediate', (
    tester,
  ) async {
    await tester.pumpWidget(_subject(controller, reduced: true));
    await _wheel(tester, 120);
    expect(controller.offset, 192);
  });

  testWidgets('raster adaptation preserves smooth wheel input', (tester) async {
    await tester.pumpWidget(_subject(controller));
    tester.binding.platformDispatcher.onReportTimings!([
      for (var i = 0; i < 12; i++)
        FrameTiming(
          vsyncStart: i * 100000,
          buildStart: i * 100000,
          buildFinish: i * 100000 + 1000,
          rasterStart: i * 100000 + 1000,
          rasterFinish: i * 100000 + 101000,
          rasterFinishWallTime: i * 100000 + 101000,
        ),
    ]);
    await tester.pump();
    expect(
      MediaQuery.disableAnimationsOf(tester.element(find.byType(ListView))),
      isTrue,
    );
    await _wheel(tester, 120);
    expect(controller.offset, 0);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(192, 0.01));
  });

  testWidgets('a route scope supplies its primary list controller', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: DesktopScrollScope(
          child: ListView.builder(
            itemExtent: 60,
            itemCount: 100,
            itemBuilder: (context, index) => Text('$index'),
          ),
        ),
      ),
    );
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    await _wheel(tester, 120);
    expect(position.pixels, 0);
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(192, 0.01));
  });
}
