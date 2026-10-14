import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

import 'dart:ui' as ui;

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/player/buffer_snapshot.dart';
import 'package:rillight/player/buffered_ranges_track.dart';

void main() {
  test('byte coverage keeps real gaps and clips invalid offsets', () {
    final coverage = BufferedByteCoverage(
      totalBytes: 1000,
      ranges: const [
        BufferedByteRange(600, 1200),
        BufferedByteRange(0, 200),
        BufferedByteRange(200, 300),
        BufferedByteRange(-5, 10),
        BufferedByteRange(500, 400),
      ],
    );
    expect(coverage.ranges, const [
      BufferedByteRange(0, 300),
      BufferedByteRange(600, 1000),
    ]);
    expect(() => coverage.ranges.clear(), throwsUnsupportedError);
  });

  test('normalizes ranges without filling a cache gap', () {
    final snapshot = BufferSnapshot(
      sessionId: 3,
      resourceId: 'media',
      representationVersion: 'v1',
      trackVersion: 1,
      sequence: 4,
      duration: const Duration(seconds: 60),
      ranges: const [
        BufferedRange(Duration(seconds: 40), Duration(seconds: 90)),
        BufferedRange(Duration(seconds: 2), Duration(seconds: 10)),
        BufferedRange(Duration(seconds: 8), Duration(seconds: 12)),
        BufferedRange(Duration(seconds: 12), Duration(seconds: 15)),
        BufferedRange(Duration(seconds: 25), Duration(seconds: 20)),
      ],
    );

    expect(snapshot.ranges, const [
      BufferedRange(Duration(seconds: 2), Duration(seconds: 15)),
      BufferedRange(Duration(seconds: 40), Duration(seconds: 60)),
    ]);
    expect(() => snapshot.ranges.clear(), throwsUnsupportedError);
  });

  test('keeps byte coverage while media time is still unknown', () {
    final snapshot = BufferSnapshot(
      sessionId: 1,
      resourceId: 'media',
      representationVersion: 'v1',
      trackVersion: 0,
      sequence: 2,
      ranges: const [],
      unknownReason: 'hlsTimingUnavailable',
      byteCoverage: BufferedByteCoverage(
        totalBytes: 100,
        ranges: const [BufferedByteRange(0, 40)],
      ),
    );
    expect(snapshot.byteCoverage, isNotNull);
    expect(snapshot.isKnown, isFalse);
    expect(snapshot.usesByteEstimate, isTrue);
    expect(snapshot.ranges, isEmpty);
    final settled = BufferSnapshot(
      sessionId: 1,
      resourceId: 'media',
      representationVersion: 'v1',
      trackVersion: 0,
      sequence: 3,
      ranges: const [BufferedRange(Duration.zero, Duration(seconds: 4))],
      byteCoverage: snapshot.byteCoverage,
    );
    expect(settled.isKnown, isTrue);
    expect(settled.ranges, const [
      BufferedRange(Duration.zero, Duration(seconds: 4)),
    ]);
  });

  test('resume preserves byte observations until media time is mapped', () {
    final snapshot = BufferSnapshot(
      sessionId: 1,
      resourceId: 'media',
      representationVersion: 'v1',
      trackVersion: 0,
      sequence: 4,
      ranges: const [],
      byteCoverage: BufferedByteCoverage(
        totalBytes: 1000,
        ranges: const [BufferedByteRange(400, 520)],
      ),
    );
    expect(snapshot.isKnown, isTrue);
    expect(snapshot.ranges, isEmpty);
    expect(snapshot.byteCoverage!.ranges, const [BufferedByteRange(400, 520)]);
    final mapped = BufferSnapshot(
      sessionId: 1,
      resourceId: 'media',
      representationVersion: 'v1',
      trackVersion: 0,
      sequence: 5,
      ranges: const [
        BufferedRange(Duration(seconds: 20), Duration(seconds: 28)),
      ],
      byteCoverage: snapshot.byteCoverage,
    );
    expect(mapped.ranges, const [
      BufferedRange(Duration(seconds: 20), Duration(seconds: 28)),
    ]);
  });

  test('rejects late versions and keeps unknown coverage empty', () {
    BufferSnapshot value(int sequence, {int track = 1, String? reason}) =>
        BufferSnapshot(
          sessionId: 5,
          resourceId: 'media',
          representationVersion: 'etag-1',
          trackVersion: track,
          sequence: sequence,
          ranges: const [],
          unknownReason: reason,
        );

    final current = value(6);
    expect(value(5).isNewerThan(current), isFalse);
    expect(value(7, track: 2).isNewerThan(current), isFalse);
    expect(value(7).isNewerThan(current), isTrue);
    expect(value(7, reason: 'unmapped').ranges, isEmpty);
    expect(value(7, reason: 'unmapped').isKnown, isFalse);
  });

  for (final direction in TextDirection.values) {
    testWidgets('seek supports keyboard and accessible steps in $direction', (
      tester,
    ) async {
      var value = .5;
      var starts = 0;
      var ends = 0;
      await tester.pumpWidget(
        CupertinoApp(
          home: Directionality(
            textDirection: direction,
            child: Center(
              child: SizedBox(
                width: 320,
                child: StatefulBuilder(
                  builder: (context, update) => PlayerSlider(
                    value: value,
                    divisions: 10,
                    onChangeStart: (_) => starts++,
                    onChanged: (next) => update(() => value = next),
                    onChangeEnd: (_) => ends++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final slider = find.byType(PlayerSlider);
      await tester.tap(slider);
      await tester.pump();
      expect(starts, 1);
      expect(ends, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(value, closeTo(direction == TextDirection.ltr ? .6 : .4, .001));
      final semantics = tester.widget<Semantics>(
        find
            .descendant(
              of: slider,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Semantics && widget.properties.slider == true,
              ),
            )
            .first,
      );
      semantics.properties.onIncrease!();
      await tester.pump();
      expect(value, closeTo(direction == TextDirection.ltr ? .7 : .5, .001));
      expect(starts, 3);
      expect(ends, 3);
    });
  }

  testWidgets('cancelled pointer does not seek or leave input occupied', (
    tester,
  ) async {
    var starts = 0;
    var ends = 0;
    var changes = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: SizedBox(
            width: 320,
            child: PlayerSlider(
              value: .5,
              onChangeStart: (_) => starts++,
              onChanged: (_) => changes++,
              onChangeEnd: (_) => ends++,
            ),
          ),
        ),
      ),
    );
    final slider = find.byType(PlayerSlider);
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.cancel();
    await tester.pump();
    expect(starts, 0);
    expect(changes, 0);
    expect(ends, 0);
    await tester.drag(slider, const Offset(50, 0));
    await tester.pump();
    expect(starts, 1);
    expect(changes, greaterThan(0));
    expect(ends, 1);
  });

  testWidgets('buffered track leaves slider input available', (tester) async {
    var selected = 0.0;
    final snapshot = BufferSnapshot(
      sessionId: 1,
      resourceId: 'media',
      representationVersion: 'etag-1',
      trackVersion: 0,
      sequence: 1,
      ranges: const [
        BufferedRange(Duration(seconds: 2), Duration(seconds: 3)),
        BufferedRange(Duration(seconds: 7), Duration(seconds: 8)),
      ],
    );
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: Center(
            child: SizedBox(
              width: 300,
              child: BufferedRangesTrack(
                snapshot: snapshot,
                duration: const Duration(seconds: 10),
                child: PlayerSlider(
                  value: selected,
                  onChanged: (value) => selected = value,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(tester.getCenter(find.byType(PlayerSlider)));
    expect(selected, closeTo(0.5, 0.1));
  });

  for (final background in [CupertinoColors.black, CupertinoColors.white]) {
    for (final direction in TextDirection.values) {
      testWidgets('seek pixels stay aligned on $background, $direction', (
        tester,
      ) async {
        final boundaryKey = GlobalKey();
        var value = 0.25;
        var snapshot = _pixelSnapshot();
        Future<void> showTrack() async {
          await tester.pumpWidget(
            CupertinoApp(
              home: Center(
                child: Directionality(
                  textDirection: direction,
                  child: RepaintBoundary(
                    key: boundaryKey,
                    child: Container(
                      decoration: BoxDecoration(color: background),
                      child: SizedBox(
                        width: 320,
                        height: 80,
                        child: Center(
                          child: BufferedRangesTrack(
                            snapshot: snapshot,
                            duration: const Duration(seconds: 100),
                            child: PlayerSlider(
                              // Non-default padding catches fixed-inset paint.
                              padding: const EdgeInsets.symmetric(
                                horizontal: 40,
                                vertical: 10,
                              ),
                              value: value,
                              onChanged: (next) => value = next,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await settle(tester);
        }

        await showTrack();
        final pixels = (await tester.runAsync(() => _capture(boundaryKey)))!;
        int x(double fraction) =>
            (40 +
                    240 *
                        (direction == TextDirection.rtl
                            ? 1 - fraction
                            : fraction))
                .round();
        expect(
          pixels.at(x(0.1), 40),
          CupertinoColors.white,
        ); // Played beats cache.
        expect(pixels.at(x(0.4), 40), const Color(0xff697783));
        expect(pixels.at(x(0.6), 40), const Color(0xff363c44)); // Real gap.
        expect(pixels.at(x(0.8), 40), const Color(0xff697783));
        expect(pixels.at(x(0.95), 40), const Color(0xff363c44));
        expect(pixels.at(x(0.69), 40), const Color(0xff363c44));
        expect(pixels.at(x(0.71), 40), const Color(0xff697783));
        expect(pixels.at(x(0.89), 40), const Color(0xff697783));
        expect(pixels.at(x(0.91), 40), const Color(0xff363c44));
        expect(pixels.at(x(0.4), 37), const Color(0xff111820));
        // The thumb extends beyond the track, and cache cannot cover its center.
        expect(pixels.at(x(0.25), 40), CupertinoColors.white);
        expect(pixels.at(x(0.25), 35), CupertinoColors.white);
        expect(pixels.at(20, 40), background);

        await tester.drag(find.byType(PlayerSlider), const Offset(40, 0));
        expect(
          value,
          direction == TextDirection.ltr ? greaterThan(0.5) : lessThan(0.5),
        );

        value = 0.25;
        snapshot = _pixelSnapshot(unknownReason: 'unmapped');
        await showTrack();
        final unknown = (await tester.runAsync(() => _capture(boundaryKey)))!;
        expect(unknown.at(x(0.4), 40), const Color(0xff363c44));
        expect(unknown.at(x(0.8), 40), const Color(0xff363c44));
        expect(unknown.at(x(0.1), 40), CupertinoColors.white);
      });
    }
  }

  testWidgets('TV track preserves discontinuous coverage and seek semantics', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: SizedBox(
              width: 300,
              child: BufferedRangesProgressIndicator(
                snapshot: _pixelSnapshot(),
                duration: const Duration(seconds: 100),
                value: 0.25,
              ),
            ),
          ),
        ),
      ),
    );
    final pixels = (await tester.runAsync(() => _capture(boundaryKey)))!;
    expect(pixels.at(30, 3), CupertinoColors.white);
    expect(pixels.at(120, 3), const Color(0xff697783));
    expect(pixels.at(180, 3), const Color(0xff363c44));
    expect(pixels.at(240, 3), const Color(0xff697783));
    expect(
      tester
          .widget<Semantics>(
            find.descendant(
              of: find.byType(BufferedRangesProgressIndicator),
              matching: find.byType(Semantics),
            ),
          )
          .properties
          .value,
      '25%',
    );
  });

  for (final reason in <String?>[null, 'containerTrackOrTimingUnknown']) {
    testWidgets(
      'combined track estimates byte coverage without a time index: $reason',
      (tester) async {
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          CupertinoApp(
            home: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: SizedBox(
                  width: 300,
                  child: BufferedRangesProgressIndicator(
                    snapshot: BufferSnapshot(
                      sessionId: 1,
                      resourceId: 'media',
                      representationVersion: 'v1',
                      trackVersion: 0,
                      sequence: 1,
                      ranges: const [],
                      unknownReason: reason,
                      byteCoverage: BufferedByteCoverage(
                        totalBytes: 100,
                        // Preserve gaps when displaying the byte estimate.
                        ranges: const [
                          BufferedByteRange(0, 1),
                          BufferedByteRange(3, 11),
                          BufferedByteRange(35, 60),
                        ],
                      ),
                    ),
                    duration: const Duration(seconds: 100),
                    value: 0.2,
                  ),
                ),
              ),
            ),
          ),
        );
        final pixels = (await tester.runAsync(() => _capture(boundaryKey)))!;
        expect(pixels.at(30, 3), CupertinoColors.white);
        expect(pixels.at(90, 3), const Color(0xff363c44));
        expect(pixels.at(120, 3), const Color(0xff697783));
        expect(pixels.at(240, 3), const Color(0xff363c44));
      },
    );
  }

  testWidgets('seek thumb and time track stay aligned before and after seek', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    for (final seconds in [4, 91]) {
      await tester.pumpWidget(
        CupertinoApp(
          home: Container(
            decoration: BoxDecoration(color: const Color(0x00000000)),
            child: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: SizedBox(
                  width: 740,
                  height: 40,
                  child: BufferedRangesTrack(
                    snapshot: BufferSnapshot(
                      sessionId: 1,
                      resourceId: 'media',
                      representationVersion: 'v1',
                      trackVersion: 0,
                      sequence: seconds,
                      ranges: const [],
                      unknownReason: 'containerTrackOrTimingUnknown',
                      byteCoverage: BufferedByteCoverage(
                        totalBytes: 100,
                        ranges: [
                          const BufferedByteRange(3, 11),
                          if (seconds == 91) const BufferedByteRange(15, 32),
                        ],
                      ),
                    ),
                    duration: const Duration(minutes: 23, seconds: 40),
                    child: PlayerSlider(
                      padding: const EdgeInsets.symmetric(horizontal: 15),
                      value: seconds / 1420,
                      onChanged: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      final pixels = (await tester.runAsync(() => _capture(boundaryKey)))!;
      final thumbX = (15 + seconds / 2).round();
      expect(pixels.at(thumbX, 16), CupertinoColors.white);
      expect(pixels.at(thumbX, 20), CupertinoColors.white);
      expect(
        pixels.at(thumbX + 10, 20),
        seconds == 91 ? const Color(0xff697783) : const Color(0xff363c44),
      );
      expect(pixels.at(80, 20), const Color(0xff697783));
      expect(
        pixels.at(150, 20),
        seconds == 91 ? const Color(0xff697783) : const Color(0xff363c44),
      );
      if (seconds == 91) expect(pixels.at(30, 20), CupertinoColors.white);
    }
  });
}

BufferSnapshot _pixelSnapshot({String? unknownReason}) => BufferSnapshot(
  sessionId: 1,
  resourceId: 'media',
  representationVersion: 'v1',
  trackVersion: 0,
  sequence: 1,
  unknownReason: unknownReason,
  byteCoverage: unknownReason == null
      ? BufferedByteCoverage(
          totalBytes: 100,
          ranges: const [BufferedByteRange(0, 100)],
        )
      : null,
  ranges: const [
    BufferedRange(Duration.zero, Duration(seconds: 50)),
    BufferedRange(Duration(seconds: 70), Duration(seconds: 90)),
  ],
);

Future<_Pixels> _capture(GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final pixels = _Pixels(bytes!.buffer.asUint8List(), image.width);
  image.dispose();
  return pixels;
}

class _Pixels {
  _Pixels(this.bytes, this.width);
  final List<int> bytes;
  final int width;

  Color at(int x, int y) {
    final index = (y * width + x) * 4;
    return Color.fromARGB(
      bytes[index + 3],
      bytes[index],
      bytes[index + 1],
      bytes[index + 2],
    );
  }
}
