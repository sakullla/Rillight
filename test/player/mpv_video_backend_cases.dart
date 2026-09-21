import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/mpv_video_backend.dart';
import 'package:rillight/player/playback_models.dart';
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
  late List<Map<String, String>> options;
  setUp(() async {
    cache = await Directory.systemTemp.createTemp('rillight-backend-test-');
    drivers = [];
    options = [];
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
      createSession: (values) async {
        options.add(values);
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
    'HTTP classification applies budgets, cache hits and close cleanup',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      var downloads = 0;
      server.listen((request) async {
        downloads++;
        request.response.headers.set('cache-control', 'max-age=600');
        request.response.headers.set('etag', '"fixture"');
        request.response.contentLength = 4;
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      });
      try {
        await backend.open(
          VideoOpenRequest(
            sessionId: 1,
            url: Uri.parse('http://127.0.0.1:${server.port}/media'),
          ),
        );
        expect(options.single['cache-on-disk'], 'no');
        expect(options.single['demuxer-max-bytes'], '${32 * 1024 * 1024}');
        final uri = Uri.parse(drivers.single.commands.first[1]);
        Future<List<int>> fetch(Uri url) async {
          final response = await (await client.getUrl(url)).close();
          return response.fold<List<int>>([], (a, b) => a..addAll(b));
        }

        expect(await fetch(uri), [1, 2, 3, 4]);
        expect(await fetch(uri), [1, 2, 3, 4]);
        expect(downloads, 1);
        expect(
          drivers.single.properties['demuxer-max-bytes'],
          '${64 * 1024 * 1024}',
        );
        final stats = (await backend.diagnostics())['cache'] as Map;
        expect(stats['memoryLimitBytes'], 32 * 1024 * 1024);
        expect(stats['diskSessionLimitBytes'], 2048 * 1024 * 1024);
        expect(stats['upstreamBytes'], 4);
        expect(stats['memoryHitBytes'], 4);
        await backend.pause();
        await backend.seek(const Duration(seconds: 2));
        expect(drivers.single.properties['pause'], 'yes');
        await backend.setSubtitleUri(
          Uri.parse('http://127.0.0.1:${server.port}/sub'),
        );
        final subtitle = Uri.parse(drivers.single.commands.last[1]);
        await fetch(subtitle);
        await fetch(subtitle);
        expect(downloads, 3, reason: 'subtitles bypass media storage');
        await backend.stop();
        final closed = (await backend.diagnostics())['cache'] as Map;
        expect(closed['closed'], isTrue);
        expect(closed['cleanup'], 'complete');
        expect(cache.listSync().whereType<Directory>(), isEmpty);
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    },
  );

  test(
    'explicit transcode and infinite source facts keep small budgets',
    () async {
      final source = PlaybackMediaSource.fromJson({
        'Id': 'live',
        'IsInfiniteStream': true,
      });
      expect(source.isInfiniteStream, isTrue);
      expect(
        PlaybackMediaSource.fromJson({'Id': 'unknown'}).isInfiniteStream,
        isFalse,
      );
      for (final request in [
        VideoOpenRequest(
          url: Uri.file('sample.mkv'),
          playMethod: PlayMethod.transcode,
        ),
        VideoOpenRequest(
          url: Uri.file('sample.mkv'),
          isInfiniteStream: source.isInfiniteStream,
        ),
      ]) {
        await backend.open(request);
        expect(options.last['demuxer-readahead-secs'], '10');
      }
    },
  );

  test(
    'extensionless HLS upgrades only after ENDLIST and can downgrade',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      var ended = true;
      server.listen((request) async {
        request.response.headers.set(
          'content-type',
          'application/vnd.apple.mpegurl',
        );
        request.response.write(
          '#EXTM3U\n#EXTINF:2,\npart.ts\n${ended ? '#EXT-X-ENDLIST\n' : ''}',
        );
        await request.response.close();
      });
      try {
        await backend.open(
          VideoOpenRequest(
            url: Uri.parse('http://127.0.0.1:${server.port}/opaque'),
          ),
        );
        final uri = Uri.parse(drivers.single.commands.first[1]);
        Future<void> fetch() async =>
            (await (await client.getUrl(uri)).close()).drain<void>();
        await fetch();
        expect(drivers.single.properties['demuxer-readahead-secs'], '120');
        ended = false;
        await fetch();
        expect(drivers.single.properties['demuxer-readahead-secs'], '10');
        final stats = (await backend.diagnostics())['cache'] as Map;
        expect(stats['memoryLimitBytes'], 8 * 1024 * 1024);
        expect(stats['pendingLimitBytes'], 2 * 1024 * 1024);
        expect(stats['diskSessionLimitBytes'], 64 * 1024 * 1024);
        ended = true;
        await backend.open(
          VideoOpenRequest(
            url: Uri.parse('http://127.0.0.1:${server.port}/opaque'),
            playMethod: PlayMethod.transcode,
          ),
        );
        final dynamicUri = Uri.parse(drivers.last.commands.first[1]);
        await (await (await client.getUrl(dynamicUri)).close()).drain<void>();
        final dynamicStats = (await backend.diagnostics())['cache'] as Map;
        expect(dynamicStats['streamPolicy'], 'conservative');
        expect(dynamicStats['diskSessionLimitBytes'], 64 * 1024 * 1024);
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    },
  );

  test('unknown-length chunked media keeps conservative budgets', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = HttpClient();
    server.listen((request) async {
      request.response.add([1, 2]);
      await request.response.flush();
      request.response.add([3, 4]);
      await request.response.close();
    });
    try {
      await backend.open(
        VideoOpenRequest(
          url: Uri.parse('http://127.0.0.1:${server.port}/unknown'),
        ),
      );
      final uri = Uri.parse(drivers.single.commands.first[1]);
      await (await (await client.getUrl(uri)).close()).drain<void>();
      final stats = (await backend.diagnostics())['cache'] as Map;
      expect(stats['streamPolicy'], 'conservative');
      expect(stats['memoryLimitBytes'], 8 * 1024 * 1024);
      expect(stats['diskSessionLimitBytes'], 64 * 1024 * 1024);
    } finally {
      client.close(force: true);
      await server.close(force: true);
    }
  });

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
    for (final seconds in [300, 301, 302]) {
      driver.eventsController.add(
        MpvEvent('property', property: 'time-pos', value: seconds),
      );
    }
    await Future<void>.delayed(Duration.zero);
    // Seek/resume and an advancing audio clock cannot replace video evidence.
    expect(opened, isFalse);
    driver.eventsController.add(const MpvEvent('first-frame'));
    await opening;
    expect(opened, isTrue);
  });

  test(
    'missing track metadata cannot masquerade as ready audio-only media',
    () async {
      await backend.dispose();
      final driver = _Driver()..tracks.clear();
      backend = MpvVideoBackend(
        wakeLock: PlaybackWakeLock(coordinator: wakeCoordinator),
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: cache,
        createSession: (_) async => driver,
      );
      await expectLater(backend.open(request(1)), throwsStateError);
      expect(driver.disposed, 1);
    },
  );

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
    'optional subtitle timeout retains selection and healthy media',
    () async {
      await backend.open(request(1));
      final driver = drivers.single;
      await backend.setSubtitleIndex(5);
      driver.subtitleTimeout = true;
      await expectLater(
        backend.setSubtitleUri(Uri.file('slow.srt')),
        throwsStateError,
      );
      expect(driver.commands.last[2], 'auto');
      expect(driver.properties['sid'], '30');
      expect(backend.isPlaying, isTrue);
      expect(driver.disposed, 0);
      expect(
        (await backend.diagnostics())['openTrace'].toString(),
        contains('subtitle-timeout-control-responsive'),
      );
    },
  );

  test('subtitle timeout with lost control still retires the media', () async {
    await backend.open(request(1));
    final driver = drivers.single;
    driver.subtitleTimeout = true;
    driver.loseControl = true;
    await expectLater(
      backend.setSubtitleUri(Uri.file('slow.srt')),
      throwsStateError,
    );
    await _until(() => driver.disposed == 1);
    expect(backend.isPlaying, isFalse);
  });

  for (final selection in ['off', 'embedded', 'external', 'new-session']) {
    test('late subtitle cannot replace $selection selection', () async {
      await backend.open(request(1));
      final driver = drivers.single;
      final uri = Uri.file('pending.srt');
      final gate = driver.subtitleGates[uri.toString()] = Completer<void>();
      final pending = backend.setSubtitleUri(uri);
      await _until(() => driver.subtitleRequested);
      switch (selection) {
        case 'off':
          await backend.setSubtitleOff();
        case 'embedded':
          await backend.setSubtitleIndex(5);
        case 'external':
          await backend.setSubtitleUri(Uri.file('new.srt'));
        case 'new-session':
          await backend.open(request(2));
      }
      final before = Map.of(drivers.last.properties);
      gate.complete();
      await pending;
      expect(drivers.last.properties, before);
      expect(backend.isPlaying, isTrue);
    });
  }

  test(
    'superseded subtitle timeout does not probe or stop a newer selection',
    () async {
      await backend.open(request(1));
      final driver = drivers.single;
      final uri = Uri.file('pending.srt');
      final gate = driver.subtitleGates[uri.toString()] = Completer<void>();
      final pending = backend.setSubtitleUri(uri);
      await _until(() => driver.subtitleRequested);
      await backend.setSubtitleIndex(5);
      gate.completeError(TimeoutException('old sub-add'));
      await pending;
      expect(driver.properties['sid'], '30');
      expect(driver.disposed, 0);
      expect(backend.isPlaying, isTrue);
    },
  );

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

  test('local native reads do not appear as network throughput', () async {
    await backend.open(request(1));
    final events = <VideoBackendEvent>[];
    backend.events.listen(events.add);
    drivers.single.eventsController.add(
      const MpvEvent('property', property: 'cache-speed', value: 2621440),
    );
    await _until(
      () => events.any((event) => event.kind == VideoEventKind.cacheSpeed),
    );
    expect(
      events
          .lastWhere((event) => event.kind == VideoEventKind.cacheSpeed)
          .value,
      0,
    );
  });
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
  bool subtitleTimeout = false;
  bool loseControl = false;
  bool subtitleRequested = false;
  final subtitleGates = <String, Completer<void>>{};
  int disposed = 0;
  @override
  Stream<MpvEvent> get events => eventsController.stream;
  @override
  String get nativeVersion => 'mpv 0.41.0';
  @override
  Future<void> command(List<String> arguments) async {
    commands.add(arguments);
    if (arguments.first == 'sub-add') {
      subtitleRequested = true;
      await subtitleGates[arguments[1]]?.future;
      if (subtitleTimeout) throw TimeoutException('sub-add timed out');
      tracks.add({'type': 'sub', 'id': 99, 'external-filename': arguments[1]});
    }
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
  Future<Object?> getProperty(String name) async {
    if (loseControl && subtitleRequested) throw StateError('Control lost');
    if (name == 'sid') return int.tryParse(properties['sid'] ?? '') ?? false;
    return name == 'track-list' ? tracks : null;
  }

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
