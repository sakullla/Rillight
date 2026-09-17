import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/mpv_video_backend.dart';
import 'package:rillight/player/playback_wake_lock.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight_player/rillight_player.dart';

void main() {
  late Directory cache;
  late MpvVideoBackend backend;
  late List<_Driver> drivers;
  late ScreenWakeLockCoordinator wakeCoordinator;
  late List<bool> wakeRequests;
  setUp(() async {
    cache = await Directory.systemTemp.createTemp('rillight-backend-test-');
    drivers = [];
    wakeRequests = [];
    wakeCoordinator = ScreenWakeLockCoordinator(
      toggle: (enabled) async {
        wakeRequests.add(enabled);
      },
    );
    backend = MpvVideoBackend(
      wakeLock: PlaybackWakeLock(coordinator: wakeCoordinator),
      settingsStore: MemoryPlayerSettingsStore(),
      diskCacheDirectory: cache,
      createSession: (options) async {
        final driver = _Driver();
        drivers.add(driver);
        return driver;
      },
    );
  });
  tearDown(() async {
    await backend.dispose();
    await cache.delete(recursive: true);
  });
  VideoOpenRequest request(int id) =>
      VideoOpenRequest(sessionId: id, url: Uri.file('sample.mkv'));

  test(
    'wake lock follows playback, pause, EOF, error and stopped sessions',
    () async {
      await backend.open(request(1));
      await wakeCoordinator.settle();
      expect(wakeRequests, [true]);
      final old = drivers.single;
      void emit(String key, Object value) => old.eventsController.add(
        MpvEvent('property', property: key, value: value),
      );
      emit('pause', true);
      await wakeCoordinator.settle();
      expect(wakeRequests.last, isFalse);
      emit('pause', false);
      await wakeCoordinator.settle();
      expect(wakeRequests.last, isTrue);
      emit('eof-reached', true);
      emit('pause', false);
      emit('core-idle', false);
      await wakeCoordinator.settle();
      expect(
        wakeRequests.last,
        isFalse,
        reason: 'EOF cannot be undone by late playing properties',
      );
      await backend.open(request(2));
      await wakeCoordinator.settle();
      expect(wakeRequests.last, isTrue);
      old.eventsController.add(const MpvEvent('file-loaded'));
      await backend.stop();
      emit('core-idle', false);
      await wakeCoordinator.settle();
      expect(wakeRequests.last, isFalse);
      await backend.open(request(3));
      drivers.last.eventsController.add(
        const MpvEvent('error', error: 'failure'),
      );
      await wakeCoordinator.settle();
      expect(wakeRequests.last, isFalse);
      await backend.dispose();
      expect(wakeCoordinator.confirmed, isFalse);
    },
  );

  test(
    'stop remains bounded while an old enable is pending and compensates it later',
    () async {
      await backend.dispose();
      final enabled = Completer<void>();
      wakeCoordinator = ScreenWakeLockCoordinator(
        waitTimeout: const Duration(milliseconds: 10),
        toggle: (value) async {
          wakeRequests.add(value);
          if (value) await enabled.future;
        },
      );
      backend = MpvVideoBackend(
        wakeLock: PlaybackWakeLock(coordinator: wakeCoordinator),
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: cache,
        createSession: (_) async {
          final driver = _Driver();
          drivers.add(driver);
          return driver;
        },
      );
      await backend.open(request(1));
      await backend.stop();
      expect(drivers.single.disposed, 1);
      expect(wakeRequests, [true]);
      enabled.complete();
      await wakeCoordinator.settle();
      expect(wakeRequests, [true, false]);
      drivers.single.eventsController.add(
        const MpvEvent('property', property: 'pause', value: false),
      );
      await wakeCoordinator.settle();
      expect(wakeRequests, [true, false]);
    },
  );

  test('each open owns a core and cannot relabel a previous event', () async {
    final events = <VideoBackendEvent>[];
    backend.events.listen(events.add);
    await backend.open(request(1));
    final old = drivers.single;
    await backend.open(request(2));
    expect(old.disposed, 1);
    old.eventsController.add(
      const MpvEvent('property', property: 'time-pos', value: 999),
    );
    drivers.last.eventsController.add(
      const MpvEvent('property', property: 'time-pos', value: 4),
    );
    await Future<void>.delayed(Duration.zero);
    expect(backend.position, const Duration(seconds: 4));
    expect(
      events
          .where((e) => e.kind == VideoEventKind.position)
          .map((e) => e.sessionId),
      [2],
    );
  });

  test('file loaded waits for the first video frame', () async {
    await backend.dispose();
    final driver = _Driver()..firstFrame = false;
    backend = MpvVideoBackend(
      wakeLock: PlaybackWakeLock(coordinator: wakeCoordinator),
      settingsStore: MemoryPlayerSettingsStore(),
      diskCacheDirectory: cache,
      createSession: (_) async => driver,
    );
    var opened = false;
    final opening = backend.open(request(1)).then((_) => opened = true);
    await _until(() => driver.commands.isNotEmpty);
    expect(opened, isFalse);
    driver.eventsController.add(const MpvEvent('first-frame'));
    await opening;
    expect(opened, isTrue);
  });

  test('audio-only media never waits for a video frame', () async {
    await backend.dispose();
    final driver = _Driver()..firstFrame = false;
    driver.tracks.removeWhere((t) => t['type'] == 'video');
    backend = MpvVideoBackend(
      wakeLock: PlaybackWakeLock(coordinator: wakeCoordinator),
      settingsStore: MemoryPlayerSettingsStore(),
      diskCacheDirectory: cache,
      createSession: (_) async => driver,
    );
    await backend.open(request(1));
    expect(backend.isPlaying, isTrue);
  });

  test(
    'stop cancels open while creation is pending and awaits disposal',
    () async {
      await backend.dispose();
      final creating = Completer<MpvSessionDriver>();
      var factoryCalled = false;
      backend = MpvVideoBackend(
        wakeLock: PlaybackWakeLock(coordinator: wakeCoordinator),
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: cache,
        createSession: (_) {
          factoryCalled = true;
          return creating.future;
        },
      );
      final opening = backend.open(request(1));
      await _until(() => factoryCalled);
      var stopped = false;
      final stopping = backend.stop().then((_) => stopped = true);
      expect(stopped, isFalse);
      final driver = _Driver();
      creating.complete(driver);
      await Future.wait([opening, stopping]);
      expect(driver.commands, isEmpty);
      expect(driver.disposed, 1);
      await backend.dispose();
      expect(driver.disposed, 1);
    },
  );

  test(
    'track selection uses unique FFmpeg index rather than mpv id or offset',
    () async {
      await backend.open(request(1));
      await backend.setAudioIndex(1);
      await backend.setSubtitleIndex(5);
      expect(drivers.single.properties['aid'], '40');
      expect(drivers.single.properties['sid'], '30');
      await expectLater(backend.setAudioIndex(40), throwsStateError);
      expect(drivers.single.properties['aid'], '40');
    },
  );

  test('an open error disposes its native core', () async {
    await backend.dispose();
    final driver = _Driver()..failOpen = true;
    backend = MpvVideoBackend(
      wakeLock: PlaybackWakeLock(coordinator: wakeCoordinator),
      settingsStore: MemoryPlayerSettingsStore(),
      diskCacheDirectory: cache,
      createSession: (_) async => driver,
    );
    await expectLater(backend.open(request(1)), throwsStateError);
    expect(driver.disposed, 1);
    expect(backend.isPlaying, isFalse);
  });

  test('fatal renderer errors stop audio and retire the core', () async {
    await backend.open(request(1));
    final events = <VideoBackendEvent>[];
    backend.events.listen(events.add);
    final driver = drivers.single;
    driver.eventsController.add(
      const MpvEvent('error', error: 'surface failed'),
    );
    await _until(() => driver.disposed == 1);
    expect(backend.isPlaying, isFalse);
    expect(events.where((e) => e.kind == VideoEventKind.error), hasLength(1));
  });

  test(
    'a surface failure before the first frame rejects open rather than cancelling silently',
    () async {
      await backend.dispose();
      final driver = _Driver()..failSurface = true;
      backend = MpvVideoBackend(
        wakeLock: PlaybackWakeLock(coordinator: wakeCoordinator),
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: cache,
        createSession: (_) async => driver,
      );
      await expectLater(backend.open(request(1)), throwsStateError);
      await _until(() => driver.disposed == 1);
      expect(backend.isPlaying, isFalse);
    },
  );
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); ++i) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(ready(), isTrue);
}

class _Driver implements MpvSessionDriver {
  final eventsController = StreamController<MpvEvent>.broadcast(sync: true);
  final commands = <List<String>>[];
  final properties = <String, String>{};
  final tracks = <Map<String, Object>>[
    {'id': 1, 'ff-index': 0, 'type': 'video'},
    {'id': 40, 'ff-index': 1, 'type': 'audio'},
    {'id': 30, 'ff-index': 5, 'type': 'sub'},
  ];
  bool firstFrame = true;
  bool failOpen = false;
  bool failSurface = false;
  int disposed = 0;
  @override
  Stream<MpvEvent> get events => eventsController.stream;
  @override
  String get nativeVersion => 'mpv 0.41.0';
  @override
  Future<void> command(List<String> arguments) async {
    commands.add(arguments);
    if (arguments.first == 'loadfile') {
      if (failOpen) throw StateError('open failed');
      eventsController.add(const MpvEvent('file-loaded'));
      if (failSurface) {
        eventsController.add(const MpvEvent('error', error: 'surface failed'));
        return;
      }
      eventsController.add(
        const MpvEvent('property', property: 'core-idle', value: false),
      );
      if (firstFrame) eventsController.add(const MpvEvent('first-frame'));
    }
  }

  @override
  Future<Object?> getProperty(String name) async =>
      name == 'track-list' ? tracks : null;
  @override
  Future<void> setProperty(String name, String value) async {
    properties[name] = value;
  }

  @override
  Future<void> dispose() async {
    disposed++;
  }

  @override
  Widget buildView() => const SizedBox();
}
