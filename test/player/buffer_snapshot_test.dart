import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
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

  for (final direction in TextDirection.values) {
    testWidgets(
      'byte-only track shows islands and a neutral fallback $direction',
      (tester) async {
        final key = GlobalKey();
        final coverage = BufferedByteCoverage(
          totalBytes: 1000,
          ranges: const [
            BufferedByteRange(0, 300),
            BufferedByteRange(600, 800),
          ],
        );
        Future<_Pixels> render(BufferedByteCoverage? value) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Directionality(
                textDirection: direction,
                child: Center(
                  child: RepaintBoundary(
                    key: key,
                    child: SizedBox(
                      width: 100,
                      child: BufferedByteCoverageBar(coverage: value),
                    ),
                  ),
                ),
              ),
            ),
          );
          return (await tester.runAsync(() => _capture(key)))!;
        }

        final pixels = await render(coverage);
        int x(int position) =>
            direction == TextDirection.rtl ? 99 - position : position;
        expect(pixels.at(x(20), 2), const Color(0xff42cbd3));
        expect(pixels.at(x(45), 2), const Color(0xff444b53));
        expect(pixels.at(x(70), 2), const Color(0xff42cbd3));
        expect(pixels.at(x(90), 2), const Color(0xff444b53));
        final neutral = await render(null);
        expect(neutral.at(x(20), 2), const Color(0xff444b53));
      },
    );
  }

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
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: BufferedRangesTrack(
                snapshot: snapshot,
                duration: const Duration(seconds: 10),
                child: Slider(
                  value: selected,
                  onChanged: (value) => selected = value,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(tester.getCenter(find.byType(Slider)));
    expect(selected, closeTo(0.5, 0.1));
  });

  for (final background in [Colors.black, Colors.white]) {
    for (final direction in TextDirection.values) {
      testWidgets('seek pixels stay aligned on $background, $direction', (
        tester,
      ) async {
        final boundaryKey = GlobalKey();
        var value = 0.25;
        var snapshot = _pixelSnapshot();
        Future<void> showTrack() async {
          await tester.pumpWidget(
            MaterialApp(
              home: Center(
                child: Directionality(
                  textDirection: direction,
                  child: RepaintBoundary(
                    key: boundaryKey,
                    child: Material(
                      color: background,
                      child: SizedBox(
                        width: 320,
                        height: 80,
                        child: Center(
                          child: SliderTheme(
                            data: const SliderThemeData(
                              thumbShape: RoundSliderThumbShape(
                                enabledThumbRadius: 8,
                              ),
                            ),
                            child: BufferedRangesTrack(
                              snapshot: snapshot,
                              duration: const Duration(seconds: 100),
                              child: Slider(
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
            ),
          );
          await tester.pumpAndSettle();
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
        expect(pixels.at(x(0.1), 40), Colors.white); // Played beats cache.
        expect(pixels.at(x(0.4), 40), const Color(0xff8eafd0));
        expect(pixels.at(x(0.6), 40), const Color(0xff363c44)); // Real gap.
        expect(pixels.at(x(0.8), 40), const Color(0xff8eafd0));
        expect(pixels.at(x(0.95), 40), const Color(0xff363c44));
        expect(pixels.at(x(0.69), 40), const Color(0xff363c44));
        expect(pixels.at(x(0.71), 40), const Color(0xff8eafd0));
        expect(pixels.at(x(0.89), 40), const Color(0xff8eafd0));
        expect(pixels.at(x(0.91), 40), const Color(0xff363c44));
        expect(pixels.at(x(0.4), 37), const Color(0xff111820));
        // The thumb extends beyond the track, and cache cannot cover its center.
        expect(pixels.at(x(0.25), 40), Colors.white);
        expect(pixels.at(x(0.25), 35), Colors.white);
        expect(pixels.at(20, 40), background);

        await tester.drag(find.byType(Slider), const Offset(40, 0));
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
        expect(unknown.at(x(0.1), 40), Colors.white);
      });
    }
  }

  testWidgets('TV track preserves discontinuous coverage and seek semantics', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
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
    expect(pixels.at(30, 3), Colors.white);
    expect(pixels.at(120, 3), const Color(0xff8eafd0));
    expect(pixels.at(180, 3), const Color(0xff363c44));
    expect(pixels.at(240, 3), const Color(0xff8eafd0));
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
}

BufferSnapshot _pixelSnapshot({String? unknownReason}) => BufferSnapshot(
  sessionId: 1,
  resourceId: 'media',
  representationVersion: 'v1',
  trackVersion: 0,
  sequence: 1,
  unknownReason: unknownReason,
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
