import 'dart:ui' show FrameTiming;

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/mobile_performance.dart' as probe;
import '../../tool/mobile_performance.dart' as report;

FrameTiming _timing(int start, {int ui = 4000, int raster = 5000}) {
  return FrameTiming(
    vsyncStart: start - 100,
    buildStart: start,
    buildFinish: start + ui,
    rasterStart: start + ui + 100,
    rasterFinish: start + ui + 100 + raster,
    rasterFinishWallTime: start + ui + 100 + raster,
  );
}

void main() {
  test(
    'tail batch stays with its frame window across a new scenario',
    () async {
      final collector = probe.MobileFrameTimingCollector();
      final first = collector.begin();
      collector.frameStarted(first, 1000);
      collector.frameStarted(first, 2000);

      final endingFirst = collector.end(first);
      var ended = false;
      endingFirst.then((_) => ended = true);
      await Future<void>.delayed(Duration.zero);
      expect(ended, isFalse);

      final second = collector.begin();
      collector.frameStarted(second, 3000);
      collector.receive([_timing(3000, ui: 3000), _timing(1000)]);
      expect(first.uiFrameMs, [4]);
      expect(second.uiFrameMs, [3]);
      expect(ended, isFalse);

      collector.receive([_timing(2000, raster: 7000)]);
      await endingFirst;
      await collector.end(second);
      expect(first.uiFrameMs, [4, 4]);
      expect(first.rasterFrameMs, [5, 7]);
      expect(first.expectedFrames, 2);
      expect(first.missingFrameTimings, 0);
      expect(first.frameTimingsComplete, isTrue);
      expect(second.expectedFrames, 1);
      expect(second.frameTimingsComplete, isTrue);
    },
  );

  test(
    'missing tail is explicit and a late batch cannot enter a new window',
    () async {
      final collector = probe.MobileFrameTimingCollector();
      final first = collector.begin();
      collector.frameStarted(first, 1000);
      await collector.end(first, timeout: Duration.zero);
      expect(first.expectedFrames, 1);
      expect(first.missingFrameTimings, 1);
      expect(first.frameTimingsComplete, isFalse);

      final second = collector.begin();
      collector.frameStarted(second, 2000);
      collector.receive([_timing(1000), _timing(2000)]);
      await collector.end(second);
      expect(first.uiFrameMs, isEmpty);
      expect(second.uiFrameMs, [4]);
    },
  );

  test('incomplete page contributes its measured frames and failure count', () {
    final summary = report.summarizeMobileSamples(
      'page/warm/device/build/profile',
      [
        {
          'complete': false,
          'firstContentMs': 20,
          'firstOperableMs': null,
          'frameBudgetMs': 16,
          'frameTimingsComplete': true,
          'missingFrameTimings': 0,
          'uiFrameMs': [20, 4],
          'rasterFrameMs': [5, 6],
        },
        {
          'complete': true,
          'firstContentMs': 30,
          'firstOperableMs': 40,
          'frameBudgetMs': 16,
          'frameTimingsComplete': false,
          'missingFrameTimings': 1,
          'uiFrameMs': [3],
          'rasterFrameMs': [7],
        },
      ],
    );
    expect(summary['samples'], 2);
    expect(summary['failures'], 1);
    expect(summary['firstContentMs'], {'median': 30.0, 'p95': 30.0});
    expect(summary['measuredFrames'], 3);
    expect(summary['overBudgetFrames'], 1);
    expect(summary['overBudgetRate'], closeTo(1 / 3, 0.0001));
    expect(summary['incompleteFrameTimingSamples'], 1);
    expect(summary['missingFrameTimings'], 1);
  });
}
