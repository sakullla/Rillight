import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/buffer_snapshot.dart';
import 'package:rillight/player/buffered_ranges_track.dart';

void main() {
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

  testWidgets('range overlay leaves slider input available', (tester) async {
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
}
