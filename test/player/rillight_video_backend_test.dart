import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/buffer_snapshot.dart';
import 'package:rillight/player/cache/cache_limits.dart';
import 'package:rillight/player/rillight_video_backend.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight_player/rillight_player.dart';

class _CoreDriver implements CorePlayer {
  final controller = StreamController<CorePlayerEvent>.broadcast();
  CorePlayerOpen? request;
  bool disposed = false;
  String? lastCommand;
  int actualHardware = 0;

  @override
  Stream<CorePlayerEvent> get events => controller.stream;

  @override
  Future<Map<String, dynamic>> open(CorePlayerOpen value) async {
    request = value;
    expect(value.url.scheme, 'http');
    expect(value.url.host, '127.0.0.1');
    expect(value.url.userInfo, isEmpty);
    expect(value.url.queryParameters.containsKey('api_key'), isFalse);
    return {
      'actualHardware': actualHardware,
      'audioIndex': 2,
      'subtitleIndex': null,
      'playableAudio': [2],
      'rejectedAudio': <int>[],
      'playableSubtitle': <int>[],
      'rejectedSubtitle': <int>[],
    };
  }

  @override
  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    lastCommand = method;
    return {
      'actualHardware': actualHardware,
      'audioIndex': 2,
      'subtitleIndex': null,
      'playableAudio': [2],
      'rejectedAudio': <int>[],
      'playableSubtitle': <int>[],
      'rejectedSubtitle': <int>[],
    };
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    disposed = true;
    await controller.close();
  }

  @override
  Widget buildView({Key? key}) => SizedBox(key: key);

  @override
  Future<Map<String, dynamic>> surfaceStatus() async => const {};

  void emit(String kind, Object value) {
    controller.add(CorePlayerEvent(request!.session, kind, value));
  }
}

class _UnauthorizedCoreDriver extends _CoreDriver {
  @override
  Future<Map<String, dynamic>> open(CorePlayerOpen value) async {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(value.url)).close();
      await response.drain<void>();
      expect(response.statusCode, HttpStatus.unauthorized);
    } finally {
      client.close();
    }
    throw StateError('Core rejected unauthorized media');
  }
}

class _PendingOpenCoreDriver extends _CoreDriver {
  final releaseOpen = Completer<void>();

  @override
  Future<Map<String, dynamic>> open(CorePlayerOpen value) async {
    request = value;
    final client = HttpClient();
    try {
      await (await (await client.getUrl(value.url)).close()).drain<void>();
      await releaseOpen.future;
      return await super.open(value);
    } finally {
      client.close(force: true);
    }
  }
}

class _FailingCoreDriver extends _CoreDriver {
  _FailingCoreDriver(this.failure);

  final Object failure;

  @override
  Future<Map<String, dynamic>> open(CorePlayerOpen value) async {
    request = value;
    throw failure;
  }
}

class _SlowDisposeCoreDriver extends _CoreDriver {
  final releaseDispose = Completer<void>();

  @override
  Future<void> dispose() async {
    await releaseDispose.future;
    await super.dispose();
  }
}

class _TrackIdCoreDriver extends _CoreDriver {
  int audioTrackId = 2;

  @override
  Future<Map<String, dynamic>> open(CorePlayerOpen value) async => {
    ...await super.open(value),
    'videoTrackId': 1,
    'audioTrackId': audioTrackId,
  };

  @override
  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async => {
    ...await super.command(method, args),
    'videoTrackId': 1,
    'audioTrackId': audioTrackId,
  };
}

void main() {
  for (final status in [HttpStatus.ok, HttpStatus.unauthorized]) {
    test(
      'transport reports HTTP $status before the core finishes opening',
      () async {
        final temp = await Directory.systemTemp.createTemp('rillight-opening-');
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        String? receivedUa;
        upstream.listen((request) async {
          receivedUa = request.headers.value('user-agent');
          request.response.statusCode = status;
          request.response.add(List<int>.filled(1024, 7));
          await request.response.close();
        });
        final driver = _PendingOpenCoreDriver();
        final backend = RillightVideoBackend(
          settingsStore: MemoryPlayerSettingsStore(),
          diskCacheDirectory: temp,
          createPlayer: () async => driver,
        );
        final reported = backend.events.firstWhere(
          (event) => status == HttpStatus.ok
              ? event.kind == VideoEventKind.cacheSpeed &&
                    (event.value as num) > 0
              : event.kind == VideoEventKind.authenticationRequired &&
                    event.value == status,
        );
        final opening = backend.open(
          VideoOpenRequest(
            sessionId: 51,
            url: Uri.parse('http://127.0.0.1:${upstream.port}/video.mp4'),
            credentialOrigin: Uri.parse('http://emby.example'),
            credentialHeaders: const {
              'User-Agent': 'Configured UA',
              'X-Emby-Token': 'secret',
            },
          ),
        );
        try {
          await reported.timeout(const Duration(seconds: 4));
          expect(driver.releaseOpen.isCompleted, isFalse);
          expect(receivedUa, 'Configured UA');
        } finally {
          driver.releaseOpen.complete();
          await opening;
          await backend.dispose();
          await upstream.close(force: true);
          await temp.delete(recursive: true);
        }
      },
    );
  }
  test('session reset clears stale cache speed before open failure', () async {
    final core = _FailingCoreDriver(
      PlatformException(code: 'playback', message: 'Core rejected media open'),
    );
    final backend = RillightVideoBackend(
      settingsStore: MemoryPlayerSettingsStore(),
      createPlayer: () async => core,
    );
    addTearDown(backend.dispose);
    final cleared = backend.events
        .where((event) => event.kind == VideoEventKind.cacheSpeed)
        .map((event) => event.value as double)
        .first;
    await expectLater(
      backend.open(
        VideoOpenRequest(
          sessionId: 99,
          url: Uri.parse('http://127.0.0.1:8765/media.mkv'),
        ),
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(await cleared, 0.0);
  });

  test('probe diagnostics expose only a numeric core failure', () async {
    final core = _FailingCoreDriver(
      PlatformException(
        code: 'playback',
        message: 'FFmpeg core error -5 signed_url=SECRET',
      ),
    );
    final backend = RillightVideoBackend(
      settingsStore: MemoryPlayerSettingsStore(),
      createPlayer: () async => core,
    );
    addTearDown(backend.dispose);
    await expectLater(
      backend.open(
        VideoOpenRequest(
          sessionId: 1,
          url: Uri.parse('http://127.0.0.1:8765/media.mkv'),
        ),
      ),
      throwsA(isA<PlatformException>()),
    );
    final diagnostics = await backend.diagnostics();
    expect(diagnostics['coreErrorCode'], -5);
    expect(diagnostics['coreOpenFailureKind'], 'ffmpeg');
    expect(diagnostics['coreErrorCode'].toString(), isNot(contains('SECRET')));
  });

  test('probe diagnostics classify an Android first frame timeout', () async {
    final core = _FailingCoreDriver(
      PlatformException(
        code: 'playback',
        message: 'Media ready / first frame timed out',
      ),
    );
    final backend = RillightVideoBackend(
      settingsStore: MemoryPlayerSettingsStore(),
      createPlayer: () async => core,
    );
    addTearDown(backend.dispose);
    await expectLater(
      backend.open(
        VideoOpenRequest(
          sessionId: 2,
          url: Uri.parse('http://127.0.0.1:8765/media.mkv'),
        ),
      ),
      throwsA(isA<PlatformException>()),
    );
    final diagnostics = await backend.diagnostics();
    expect(diagnostics['coreErrorCode'], isNull);
    expect(diagnostics['coreOpenFailureKind'], 'firstFrameTimeout');
  });

  test('probe diagnostics classify a desktop first frame timeout', () async {
    final core = _FailingCoreDriver(
      TimeoutException('Core did not render the first frame'),
    );
    final backend = RillightVideoBackend(
      settingsStore: MemoryPlayerSettingsStore(),
      createPlayer: () async => core,
    );
    addTearDown(backend.dispose);
    await expectLater(
      backend.open(
        VideoOpenRequest(url: Uri.parse('http://127.0.0.1:8765/media.mkv')),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(
      (await backend.diagnostics())['coreOpenFailureKind'],
      'firstFrameTimeout',
    );
  });

  test('container track IDs follow confirmed native audio changes', () async {
    final core = _TrackIdCoreDriver();
    final backend = RillightVideoBackend(
      settingsStore: MemoryPlayerSettingsStore(),
      createPlayer: () async => core,
    );
    addTearDown(backend.dispose);
    await backend.open(
      VideoOpenRequest(
        sessionId: 71,
        url: Uri.parse('http://127.0.0.1:8765/media.mp4'),
      ),
    );
    var data = await backend.diagnostics();
    expect(data['timelineVideoTrackIdentified'], true);
    expect(data['timelineAudioTrackIdentified'], true);
    expect(data['timelineTrackSelectionVersion'], 1);
    core.audioTrackId = 3;
    await backend.setAudioIndex(2);
    data = await backend.diagnostics();
    expect(data['timelineTrackSelectionVersion'], 2);
    expect(backend.bufferSnapshot.ranges, isEmpty);
  });

  test(
    'same-session reopen clears track cache before old core stops',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'rillight-core-reopen-',
      );
      final first = _SlowDisposeCoreDriver();
      final second = _CoreDriver();
      var creates = 0;
      final backend = RillightVideoBackend(
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: temp,
        createPlayer: () async => creates++ == 0 ? first : second,
      );
      addTearDown(() async {
        if (!first.releaseDispose.isCompleted) first.releaseDispose.complete();
        await backend.dispose();
        await temp.delete(recursive: true);
      });
      final request = VideoOpenRequest(
        sessionId: 29,
        url: Uri.parse('http://127.0.0.1:8765/stream.mp4'),
      );
      final snapshots = <BufferSnapshot>[];
      final subscription = backend.events
          .where((event) => event.kind == VideoEventKind.bufferSnapshot)
          .listen((event) => snapshots.add(event.value as BufferSnapshot));
      addTearDown(subscription.cancel);

      await backend.open(request);
      await backend.setAudioIndex(2);
      final before = backend.bufferSnapshot;
      expect(before.trackVersion, greaterThan(0));
      backend.bufferSnapshot = BufferSnapshot(
        sessionId: before.sessionId,
        resourceId: before.resourceId,
        representationVersion: before.representationVersion,
        trackVersion: before.trackVersion,
        sequence: before.sequence,
        ranges: const [
          BufferedRange(Duration(seconds: 10), Duration(seconds: 20)),
        ],
      );

      final reopening = backend.open(request);
      final cleared = backend.bufferSnapshot;
      expect(first.disposed, isFalse);
      expect(cleared.ranges, isEmpty);
      expect(cleared.unknownReason, 'reconnecting');
      expect(cleared.sessionId, before.sessionId);
      expect(cleared.sequence, greaterThan(before.sequence));
      expect(cleared.trackVersion, greaterThan(before.trackVersion));
      first.releaseDispose.complete();
      await reopening;
      expect(second.request, isNotNull);
      expect(snapshots.last.sequence, greaterThanOrEqualTo(cleared.sequence));
      expect(
        snapshots.last.trackVersion,
        greaterThanOrEqualTo(cleared.trackVersion),
      );
      expect(backend.bufferSnapshot.unknownReason, isNot('stopped'));
    },
  );

  test('stop releases the previous transport before the next open', () async {
    final temp = await Directory.systemTemp.createTemp('rillight-core-stop-');
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      request.response.add(List<int>.filled(1024, 0));
      await request.response.close();
    });
    final drivers = <_CoreDriver>[
      _CoreDriver(),
      _CoreDriver(),
      _CoreDriver(),
      _CoreDriver(),
    ];
    var created = 0;
    final backend = RillightVideoBackend(
      settingsStore: MemoryPlayerSettingsStore(),
      diskCacheDirectory: temp,
      createPlayer: () async => drivers[created++],
    );
    addTearDown(() async {
      await backend.dispose();
      await upstream.close(force: true);
      await temp.delete(recursive: true);
    });

    Future<void> openEpisode(int sessionId) {
      return backend.open(
        VideoOpenRequest(
          sessionId: sessionId,
          url: Uri.parse('http://127.0.0.1:${upstream.port}/episode.mp4'),
        ),
      );
    }

    await openEpisode(1);
    var diagnostics = await backend.diagnostics();
    expect(diagnostics['transportAttached'], isTrue);
    expect(diagnostics['memoryLimitBytes'], 8 * 1024 * 1024);
    expect(diagnostics['pendingLimitBytes'], defaultCachePendingBytes);
    backend.bufferSnapshot = BufferSnapshot(
      sessionId: backend.bufferSnapshot.sessionId,
      resourceId: backend.bufferSnapshot.resourceId,
      representationVersion: backend.bufferSnapshot.representationVersion,
      trackVersion: backend.bufferSnapshot.trackVersion,
      sequence: backend.bufferSnapshot.sequence,
      ranges: const [BufferedRange(Duration(seconds: 1), Duration(seconds: 2))],
    );

    await openEpisode(2);
    expect(drivers[0].disposed, isTrue);
    expect(drivers[1].disposed, isFalse);
    diagnostics = await backend.diagnostics();
    expect(diagnostics['transportAttached'], isTrue);
    expect(diagnostics['memoryLimitBytes'], 8 * 1024 * 1024);
    expect(diagnostics['pendingLimitBytes'], defaultCachePendingBytes);

    await openEpisode(3);
    expect(drivers[1].disposed, isTrue);
    expect(drivers[2].disposed, isFalse);
    await backend.stop();
    expect(drivers[2].disposed, isTrue);
    expect(backend.bufferSnapshot.ranges, isEmpty);
    expect(backend.bufferSnapshot.unknownReason, 'stopped');
    diagnostics = await backend.diagnostics();
    expect(diagnostics['transportAttached'], isFalse);
    expect(diagnostics['transportDiagnosticsStatus'], 'detached');

    await openEpisode(4);
    expect(diagnostics['transportAttached'], isFalse);
    diagnostics = await backend.diagnostics();
    expect(diagnostics['transportAttached'], isTrue);
    expect(diagnostics['memoryLimitBytes'], 8 * 1024 * 1024);
    expect(diagnostics['pendingLimitBytes'], defaultCachePendingBytes);
  });

  test(
    'owned backend sends only sealed URL and filters stale core events',
    () async {
      final temp = await Directory.systemTemp.createTemp('rillight-core-test-');
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        request.response.add(List<int>.filled(1024, 0));
        await request.response.close();
      });
      final driver = _CoreDriver();
      final backend = RillightVideoBackend(
        settingsStore: MemoryPlayerSettingsStore(
          const PlayerSettings(hardwareDecoding: HardwareDecodingMode.off),
        ),
        diskCacheDirectory: temp,
        createPlayer: () async => driver,
      );
      addTearDown(() async {
        await backend.dispose();
        await upstream.close(force: true);
        await temp.delete(recursive: true);
      });
      final events = <VideoBackendEvent>[];
      final subscription = backend.events.listen(events.add);
      addTearDown(subscription.cancel);
      await backend.open(
        VideoOpenRequest(
          sessionId: 17,
          url: Uri.parse(
            'http://127.0.0.1:${upstream.port}/video.mp4?api_key=secret',
          ),
        ),
      );
      expect(driver.request, isNotNull);
      expect(driver.request!.hardware, CoreHardware.software);
      var diagnostics = await backend.diagnostics();
      expect(diagnostics['coreActualHardware'], 0);
      expect(diagnostics['coreActualHardwareName'], 'software');
      driver.actualHardware = 4;
      await backend.setAudioIndex(2);
      diagnostics = await backend.diagnostics();
      expect(diagnostics['coreActualHardware'], 4);
      expect(diagnostics['coreActualHardwareName'], 'vaapi');
      expect(
        driver.request!.url,
        isNot(
          Uri.parse(
            'http://127.0.0.1:${upstream.port}/video.mp4?api_key=secret',
          ),
        ),
      );
      driver.emit('duration', 120000);
      driver.emit('position', 5000);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(backend.duration, const Duration(minutes: 2));
      expect(backend.position, const Duration(seconds: 5));
      expect(
        events
            .where((event) => event.kind == VideoEventKind.position)
            .single
            .sessionId,
        17,
      );
      await backend.stop();
      expect(driver.disposed, isTrue);
      expect(backend.bufferSnapshot.ranges, isEmpty);
    },
  );

  test(
    'upstream 401 reports authentication required after failed open',
    () async {
      final temp = await Directory.systemTemp.createTemp('rillight-core-auth-');
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
      });
      final backend = RillightVideoBackend(
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: temp,
        createPlayer: () async => _UnauthorizedCoreDriver(),
      );
      addTearDown(() async {
        await backend.dispose();
        await upstream.close(force: true);
        await temp.delete(recursive: true);
      });
      final native = <Map<String, dynamic>>[];
      final subscription = backend.nativeEvents.listen(native.add);
      addTearDown(subscription.cancel);
      await expectLater(
        backend.open(
          VideoOpenRequest(
            sessionId: 3,
            url: Uri.parse('http://127.0.0.1:${upstream.port}/denied.mp4'),
          ),
        ),
        throwsStateError,
      );
      expect(
        native.where((event) => event['kind'] == 'authenticationRequired'),
        hasLength(1),
      );
      final diagnostics = await backend.diagnostics();
      expect(diagnostics['authenticationStatus'], HttpStatus.unauthorized);
      expect(backend.lastFailure, contains('unauthorized'));
    },
  );

  test('transcode marks only external subtitle tracks as external', () async {
    final temp = await Directory.systemTemp.createTemp('rillight-core-tracks-');
    final driver = _CoreDriver();
    final backend = RillightVideoBackend(
      settingsStore: MemoryPlayerSettingsStore(),
      diskCacheDirectory: temp,
      createPlayer: () async => driver,
    );
    addTearDown(() async {
      await backend.dispose();
      await temp.delete(recursive: true);
    });
    await backend.open(
      VideoOpenRequest(
        sessionId: 4,
        url: Uri.parse('http://127.0.0.1:8765/stream.m3u8'),
        playMethod: PlayMethod.transcode,
        mediaStreams: const [
          MediaStreamInfo(index: 0, type: 'Video'),
          MediaStreamInfo(index: 1, type: 'Audio'),
          MediaStreamInfo(
            index: 2,
            type: 'Subtitle',
            codec: 'srt',
            deliveryMethod: 'External',
          ),
        ],
      ),
    );
    expect(driver.request!.streams.map((track) => track.isExternal), [
      false,
      false,
      true,
    ]);
  });

  test('confirmed external subtitle retains its server track index', () async {
    final temp = await Directory.systemTemp.createTemp('rillight-core-srt-');
    final subtitleRoot = await Directory.systemTemp.createTemp(
      'rillight-subtitles-',
    );
    final subtitle = File('${subtitleRoot.path}/selected.srt');
    await subtitle.writeAsString('1\n00:00:00,000 --> 00:00:01,000\nHello\n');
    final driver = _CoreDriver();
    final backend = RillightVideoBackend(
      settingsStore: MemoryPlayerSettingsStore(),
      diskCacheDirectory: temp,
      createPlayer: () async => driver,
    );
    addTearDown(() async {
      await backend.dispose();
      await subtitleRoot.delete(recursive: true);
      await temp.delete(recursive: true);
    });
    await backend.open(
      VideoOpenRequest(
        sessionId: 5,
        url: Uri.parse('http://127.0.0.1:8765/stream.mkv'),
        mediaStreams: const [
          MediaStreamInfo(index: 5, type: 'Subtitle', isExternal: true),
        ],
      ),
    );
    expect(await backend.setSubtitleUri(subtitle.uri, index: 5), isTrue);
    expect(driver.lastCommand, 'subtitleUri');
    expect(backend.selectedSubtitleIndex, 5);
    expect((await backend.diagnostics())['selectedSubtitleIndex'], 5);
    await backend.setSubtitleOff();
    expect(backend.selectedSubtitleIndex, isNull);
  });
}
