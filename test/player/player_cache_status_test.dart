import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/player/buffer_snapshot.dart';
import 'package:rillight/player/network_throughput.dart';
import 'package:rillight/player/player_cache_status.dart';

BufferSnapshot snapshot(List<BufferedRange> ranges, {String? unknown}) =>
    BufferSnapshot(
      sessionId: 1,
      resourceId: 'fixture',
      representationVersion: 'one',
      trackVersion: 0,
      sequence: 1,
      ranges: ranges,
      unknownReason: unknown,
    );

Widget host(
  BufferSnapshot value, {
  num speed = 0,
  double fontSize = 12,
  double width = 400,
  Duration position = Duration.zero,
}) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: SizedBox(
      width: width,
      child: PlayerCacheStatus(
        snapshot: value,
        bytesPerSecond: speed,
        position: position,
        duration: const Duration(minutes: 10),
        textStyle: TextStyle(fontSize: fontSize),
      ),
    ),
  ),
);

void main() {
  testWidgets('download and unknown coverage coexist, including a zero rate', (
    tester,
  ) async {
    final stale = snapshot(const [
      BufferedRange(Duration.zero, Duration(minutes: 5)),
    ], unknown: 'cacheUncertain');
    await tester.pumpWidget(host(stale, speed: 2 * 1024 * 1024));
    expect(find.text('2.0 MB/s'), findsOneWidget);
    expect(find.text('缓存时间范围暂不可用'), findsOneWidget);
    expect(find.textContaining('前方缓存'), findsNothing);
    await tester.pumpWidget(host(stale));
    expect(find.text('0 KB/s'), findsOneWidget);
    expect(find.text('缓存时间范围暂不可用'), findsOneWidget);
  });

  testWidgets('forward coverage stops at a gap and invalidation clears it', (
    tester,
  ) async {
    final ranges = snapshot(const [
      BufferedRange(Duration.zero, Duration(seconds: 20)),
      BufferedRange(Duration(seconds: 50), Duration(minutes: 2)),
    ]);
    await tester.pumpWidget(host(ranges, position: const Duration(seconds: 5)));
    expect(find.text('前方缓存 0:15'), findsOneWidget);
    await tester.pumpWidget(
      host(ranges, position: const Duration(seconds: 30)),
    );
    expect(find.text('已有缓存片段'), findsOneWidget);
    await tester.pumpWidget(host(snapshot(const [])));
    expect(find.text('暂无可用缓存'), findsOneWidget);
    expect(find.text('0 KB/s'), findsOneWidget);
  });

  testWidgets(
    'complete coverage and TV typography remain readable in narrow layouts',
    (tester) async {
      await tester.pumpWidget(
        host(
          snapshot(const [BufferedRange(Duration.zero, Duration(minutes: 10))]),
          fontSize: 24,
          width: 180,
        ),
      );
      expect(find.text('已缓存全片'), findsOneWidget);
      expect(tester.widget<Text>(find.text('0 KB/s')).style!.fontSize, 24);
      final mark = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is InboundSpeedMarkPainter,
      );
      expect(tester.getSize(mark), const Size(16, 22));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        host(
          snapshot(const [], unknown: 'indexUnavailable'),
          fontSize: 24,
          width: 180,
        ),
      );
      expect(find.text('缓存时间范围暂不可用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
