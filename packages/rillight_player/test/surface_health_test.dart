import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight_player/src/surface_health.dart';

List<Map<String, Object>> video({
  num? fps = 24,
  bool image = false,
  bool albumart = false,
  bool selected = true,
}) => [
  {
    'type': 'video',
    'selected': selected,
    'image': image,
    'albumart': albumart,
    'demux-fps': ?fps,
  },
];

void main() {
  test(
    'normal frames remain healthy even when their pictures are identical',
    () async {
      final h = _Harness();
      addTearDown(h.health.close);
      await h.load();
      await h.advance(20, publishFrames: true);
      expect(h.errors, isEmpty);
      expect(h.statuses, isNotEmpty);
      expect(h.trackReads, 1);
    },
  );

  test(
    'continuous clock progress without new frames produces one error',
    () async {
      final h = _Harness();
      addTearDown(h.health.close);
      await h.load();
      await h.advance(7);
      expect(h.errors, isEmpty);
      await h.advance(2);
      expect(h.errors.single, contains('frames stopped'));
      final count = h.statusReads;
      await h.advance(20);
      expect(h.errors, hasLength(1));
      expect(h.statusReads, count);
    },
  );

  test(
    'a stationary playback position never implies a renderer stall',
    () async {
      final h = _Harness();
      addTearDown(h.health.close);
      await h.load();
      await h.advance(7);
      await h.advance(20, advancePosition: false);
      expect(h.errors, isEmpty);
      await h.advance(7);
      expect(h.errors, isEmpty);
      await h.advance(2);
      expect(h.errors, hasLength(1));
    },
  );

  for (final property in ['pause', 'paused-for-cache', 'core-idle']) {
    test(
      '$property suspends detection and grants fresh time on recovery',
      () async {
        final h = _Harness();
        addTearDown(h.health.close);
        await h.load();
        await h.advance(7);
        h.property(property, true);
        // Even a late/misordered time-pos update cannot defeat this exclusion.
        await h.advance(20);
        expect(h.errors, isEmpty);
        h.property(property, false);
        await h.advance(7);
        expect(h.errors, isEmpty);
        await h.advance(2);
        expect(h.errors, hasLength(1));
      },
    );
  }

  test('seek and playback restart reset the grace period', () async {
    final h = _Harness();
    addTearDown(h.health.close);
    await h.load();
    await h.advance(7);
    h.health.event('seek');
    h.position = 90;
    h.property('time-pos', h.position);
    await h.advance(20);
    expect(h.errors, isEmpty);
    h.health.event('playback-restart');
    await h.advance(7);
    expect(h.errors, isEmpty);
    await h.advance(2);
    expect(h.errors, hasLength(1));
  });

  for (final event in ['eof-reached', 'end-file']) {
    test('$event keeps the normal last frame without a false stall', () async {
      final h = _Harness();
      addTearDown(h.health.close);
      await h.load();
      await h.advance(7);
      if (event == 'eof-reached') {
        h.property(event, true);
      } else {
        h.health.event(event);
      }
      await h.advance(20);
      expect(h.errors, isEmpty);
    });
  }

  test(
    'new load and reset native frame counter get a fresh grace period',
    () async {
      final h = _Harness();
      addTearDown(h.health.close);
      h.frames = 100;
      await h.load();
      await h.advance(7);
      h.frames = 0;
      await h.health.poll();
      await h.advance(7);
      expect(h.errors, isEmpty);
      await h.load();
      await h.advance(7);
      expect(h.errors, isEmpty);
      expect(h.trackReads, 2);
      await h.advance(2);
      expect(h.errors, hasLength(1));
    },
  );

  final excluded = <String, Object?>{
    'audio': [
      {'type': 'audio', 'selected': true},
    ],
    'cover art': video(albumart: true),
    'static image': video(image: true),
    'unselected video': video(selected: false),
    'unknown fps': video(fps: null),
    'very low fps': video(fps: .5),
    'invalid fps': video(fps: double.nan),
    'unknown tracks': null,
  };
  for (final entry in excluded.entries) {
    test('${entry.key} is exempt from clock/frame stall inference', () async {
      final h = _Harness()..tracks = entry.value;
      addTearDown(h.health.close);
      await h.load();
      await h.advance(30);
      expect(h.errors, isEmpty);
    });
  }

  test('newer observed tracks win over a delayed initial track read', () async {
    final h = _Harness();
    addTearDown(h.health.close);
    final pending = Completer<Object?>();
    h.trackQuery = () => pending.future;
    await h.load();
    h.property('track-list', video(albumart: true));
    pending.complete(video());
    await Future<void>.delayed(Duration.zero);
    await h.advance(20);
    expect(h.errors, isEmpty);
    expect(h.trackReads, 1);
  });

  test(
    'track replies from an old load cannot arm the current audio session',
    () async {
      final h = _Harness();
      addTearDown(h.health.close);
      final pending = Completer<Object?>();
      h.trackQuery = () => pending.future;
      await h.load();
      h.trackQuery = null;
      h.tracks = const <Object>[];
      await h.load();
      pending.complete(video());
      await Future<void>.delayed(Duration.zero);
      await h.advance(20);
      expect(h.errors, isEmpty);
      expect(h.trackReads, 2);
    },
  );

  test(
    'status timeout is bounded, single flight and never accepts a late reply',
    () async {
      final h = _Harness(statusTimeout: const Duration(milliseconds: 10));
      addTearDown(h.health.close);
      final pending = Completer<Map<String, dynamic>?>();
      h.statusQuery = () => pending.future;
      final poll = h.health.poll();
      await h.health.poll();
      expect(h.statusReads, 1);
      await poll;
      expect(h.errors.single, contains('timed out'));
      pending.complete({'frames': 100});
      await Future<void>.delayed(Duration.zero);
      await h.health.poll();
      expect(h.statuses, isEmpty);
      expect(h.errors, hasLength(1));
      expect(h.statusReads, 1);
    },
  );

  for (final fail in [false, true]) {
    test(
      'close suppresses a late status ${fail ? 'error' : 'success'} and cancels its deadline',
      () async {
        final h = _Harness(statusTimeout: const Duration(milliseconds: 10));
        final pending = Completer<Map<String, dynamic>?>();
        h.statusQuery = () => pending.future;
        final poll = h.health.poll();
        h.health.close();
        h.health.close();
        await poll;
        if (fail) {
          pending.completeError(StateError('late status error'));
        } else {
          pending.complete({'frames': 1});
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await h.health.poll();
        expect(h.errors, isEmpty);
        expect(h.statuses, isEmpty);
        expect(h.statusReads, 1);
      },
    );
  }

  test(
    'a status reply from a preceding load cannot publish a first frame',
    () async {
      final h = _Harness();
      addTearDown(h.health.close);
      final pending = Completer<Map<String, dynamic>?>();
      h.statusQuery = () => pending.future;
      final poll = h.health.poll();
      h.health.event('start-file');
      pending.complete({'frames': 999});
      await poll;
      expect(h.statuses, isEmpty);
      h.statusQuery = null;
      await h.health.poll();
      expect(h.statuses.single['frames'], 0);
      expect(h.errors, isEmpty);
    },
  );

  for (final value in [
    null,
    {'frames': 'bad'},
    {'frames': 7, 'error': 'render failed'},
  ]) {
    test('invalid/failed native status $value is reported once', () async {
      final h = _Harness();
      addTearDown(h.health.close);
      h.statusQuery = () async => value;
      await h.health.poll();
      await h.health.poll();
      expect(h.errors, hasLength(1));
      expect(h.statuses, isEmpty);
      expect(h.statusReads, 1);
    });
  }
}

class _Harness {
  _Harness({Duration statusTimeout = const Duration(seconds: 5)}) {
    health = SurfaceHealth(
      now: () => now,
      statusTimeout: statusTimeout,
      readStatus: () {
        ++statusReads;
        return statusQuery?.call() ?? Future.value({'frames': frames});
      },
      readTracks: () {
        ++trackReads;
        return trackQuery?.call() ?? Future.value(tracks);
      },
      onStatus: statuses.add,
      onError: errors.add,
    );
  }
  late final SurfaceHealth health;
  Duration now = Duration.zero;
  double position = 0;
  int frames = 0;
  int statusReads = 0;
  int trackReads = 0;
  Object? tracks = video();
  Future<Object?> Function()? trackQuery;
  Future<Map<String, dynamic>?> Function()? statusQuery;
  final errors = <String>[];
  final statuses = <Map<String, dynamic>>[];

  void property(String name, Object? value) =>
      health.event('property', property: name, value: value);

  Future<void> load() async {
    health.event('start-file');
    property('pause', false);
    property('paused-for-cache', false);
    property('core-idle', false);
    position = 0;
    property('time-pos', position);
    health.event('file-loaded');
    await Future<void>.delayed(Duration.zero);
    await health.poll();
  }

  Future<void> advance(
    int seconds, {
    bool publishFrames = false,
    bool advancePosition = true,
  }) async {
    for (var tick = 0; tick < seconds * 4; tick++) {
      now += const Duration(milliseconds: 250);
      if (advancePosition) {
        position += .25;
        property('time-pos', position);
      }
      if (publishFrames) ++frames;
      await health.poll();
    }
  }
}
