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
  Map<String, Object?> lastArgs = const {};
  final commands = <String>[];
  Map<String, Object?>? enhancementArgs;
  Map<String, Object?>? deadlineArgs;
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
    commands.add(method);
    if (method == 'enhancement') enhancementArgs = args;
    if (method == 'frameDeadline') deadlineArgs = args;
    lastCommand = method;
    lastArgs = args;
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

class _WarmHandoffCoreDriver extends _CoreDriver {
  Future<void> _read(String range) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(this.request!.url);
      request.headers.set('range', range);
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      await response.drain<void>();
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<Map<String, dynamic>> open(CorePlayerOpen value) async {
    final result = await super.open(value);
    emit('duration', 60000);
    await _read('bytes=0-65535');
    return result;
  }

  @override
  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    if (method == 'seek') await _read('bytes=131072-262143');
    return super.command(method, args);
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

class _FrameOutputCoreDriver extends _CoreDriver {
  @override
  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    final base = await super.command(method, args);
    if (method == 'enhancement') {
      return {
        ...base,
        'dolbyVisionProfile': 7,
        'dolbyVisionCompatibility': 6,
        'videoOutputKind': 3,
        'audioDelivery': 4,
        'audioChannels': 8,
        'audioAtmos': 1,
        'requestedInterpolation': 2,
        'effectiveInterpolation': 2,
        'reasonInterpolation': 1,
      };
    }
    if (method == 'outputStatus') {
      return {
        ...base,
        'dolbyVisionProfile': 7,
        'dolbyVisionCompatibility': 6,
        'videoOutputKind': 1,
        'doviReconstruction': 3,
        'audioDelivery': 3,
        'audioChannels': 6,
        'audioAtmos': 0,
        'requestedInterpolation': 2,
        'effectiveInterpolation': 0,
        'reasonInterpolation': 4,
        'outputColorSpace': 'scRGB',
        'hdrOutput': false,
        'hdrDisplayActive': false,
      };
    }
    return base;
  }
}

class _StaleOutputCoreDriver extends _CoreDriver {
  Map<String, dynamic> _fields({
    required int kind,
    required int delivery,
    required int effective,
    required int reason,
    required int epoch,
  }) {
    return {
      'dolbyVisionProfile': 7,
      'dolbyVisionCompatibility': 6,
      'videoOutputKind': kind,
      'doviReconstruction': kind == 1 ? 3 : 2,
      'audioDelivery': delivery,
      'audioChannels': kind == 3 ? 8 : 6,
      'audioAtmos': kind == 3 ? 1 : 0,
      'requestedInterpolation': 2,
      'effectiveInterpolation': effective,
      'reasonInterpolation': reason,
      'outputColorSpace': 'scRGB',
      'hdrDisplayActive': true,
      'hdrOutput': false,
      'outputEpoch': epoch,
    };
  }

  @override
  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    final base = await super.command(method, args);
    if (method == 'enhancement') {
      return {
        ...base,
        ..._fields(kind: 3, delivery: 4, effective: 2, reason: 1, epoch: 1),
      };
    }
    if (method == 'outputStatus') {
      // The command captured native Dolby before this yield. The frame path
      // publishes SDR while that result is still in flight.
      await Future<void>.delayed(Duration.zero);
      emit(
        'outputStatus',
        _fields(kind: 1, delivery: 3, effective: 0, reason: 4, epoch: 2),
      );
      emit('position', 2400);
      await Future<void>.delayed(Duration.zero);
      return {
        ...base,
        ..._fields(kind: 3, delivery: 4, effective: 2, reason: 1, epoch: 1),
      };
    }
    return base;
  }
}

class _LateFrameCoreDriver extends _CoreDriver {
  int outputReads = 0;

  Map<String, dynamic> _fields({
    required int kind,
    required int epoch,
    required int effective,
    required int delivery,
    required int reason,
  }) {
    return {
      'dolbyVisionProfile': 7,
      'dolbyVisionCompatibility': 6,
      'videoOutputKind': kind,
      'audioDelivery': delivery,
      'audioChannels': kind == 3 ? 8 : 6,
      'audioAtmos': kind == 3 ? 1 : 0,
      'requestedInterpolation': 2,
      'effectiveInterpolation': effective,
      'reasonInterpolation': reason,
      'outputEpoch': epoch,
    };
  }

  @override
  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    final base = await super.command(method, args);
    if (method == 'enhancement') {
      return {
        ...base,
        ..._fields(kind: 3, delivery: 4, epoch: 1, effective: 2, reason: 1),
      };
    }
    if (method == 'outputStatus') {
      outputReads++;
      emit('position', 1000 + outputReads * 100);
      if (outputReads < 3) {
        return {
          ...base,
          ..._fields(kind: 3, delivery: 4, epoch: 1, effective: 2, reason: 1),
        };
      }
      return {
        ...base,
        ..._fields(kind: 1, delivery: 3, epoch: 2, effective: 0, reason: 4),
      };
    }
    return base;
  }
}

class _RejectedAudioCoreDriver extends _CoreDriver {
  int attempts = 0;

  @override
  Future<Map<String, dynamic>> open(CorePlayerOpen value) async => {
    ...await super.open(value),
    'playableAudio': [2, 3],
  };

  @override
  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    if (method == 'audio') {
      attempts++;
      throw const CoreTrackSelectionException('audio', -1128613112);
    }
    return super.command(method, args);
  }
}

void main() {
  late Directory isolatedCache;
  setUp(() async {
    isolatedCache = await Directory.systemTemp.createTemp(
      'rillight-backend-test-',
    );
    // Never join the real player's shared quota while running unit tests.
    // A test's default 2 GiB budget can evict an active 8 GiB session.
    addTearDown(() => isolatedCache.delete(recursive: true));
  });
  test(
    'slow recovery headers do not trigger premature startup source renewal',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      upstream.listen((request) async {
        if (++requests == 1) {
          request.response.statusCode = 502;
        } else {
          await Future<void>.delayed(const Duration(seconds: 31));
          request.response.contentLength = 8;
          request.response.add(List.filled(8, 9));
        }
        await request.response.close();
      });
      final driver = _PendingOpenCoreDriver()..releaseOpen.complete();
      final backend = RillightVideoBackend(
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: isolatedCache,
        createPlayer: () async => driver,
      );
      final renewals = <VideoBackendEvent>[];
      final subscription = backend.events.listen((event) {
        if (event.kind == VideoEventKind.sourceRefreshRequired) {
          renewals.add(event);
        }
      });
      try {
        await backend
            .open(
              VideoOpenRequest(
                sessionId: 74,
                url: Uri.parse('http://127.0.0.1:${upstream.port}/media'),
              ),
            )
            .timeout(const Duration(seconds: 36));
        expect(requests, 2);
        expect(renewals, isEmpty);
      } finally {
        await subscription.cancel();
        await backend.dispose();
        await upstream.close(force: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
  test(
    'stalled initial open renews its source before the core is ready',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final held = <HttpResponse>[];
      upstream.listen((request) async {
        if (request.uri.path == '/old') {
          held.add(request.response);
          return;
        }
        request.response.contentLength = 8;
        request.response.add(List.filled(8, 9));
        await request.response.close();
      });
      final driver = _PendingOpenCoreDriver();
      final backend = RillightVideoBackend(
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: isolatedCache,
        createPlayer: () async => driver,
      );
      final refresh = backend.events.firstWhere(
        (event) => event.kind == VideoEventKind.sourceRefreshRequired,
      );
      final opening = backend.open(
        VideoOpenRequest(
          sessionId: 73,
          url: Uri.parse('http://127.0.0.1:${upstream.port}/old'),
        ),
      );
      // Observe errors immediately, including during cleanup of a failing test.
      final opened = expectLater(opening, completes);
      try {
        final event = await refresh.timeout(const Duration(seconds: 50));
        expect(event.value, 408);
        expect((await backend.diagnostics())['openPhase'], 'openingCore');
        await backend.refreshSourceUrl(
          Uri.parse('http://127.0.0.1:${upstream.port}/new'),
        );
        driver.releaseOpen.complete();
        await opened.timeout(const Duration(seconds: 5));
        expect((await backend.diagnostics())['sourceRenewalCount'], 1);
      } finally {
        if (!driver.releaseOpen.isCompleted) driver.releaseOpen.complete();
        await backend.dispose();
        for (final response in held) {
          try {
            await response.close();
          } catch (_) {}
        }
        await upstream.close(force: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'stalled live downloader renews its source without discarding cached bytes',
    () async {
      const total = 16 * 1024 * 1024;
      final temp = await Directory.systemTemp.createTemp(
        'rillight-source-renewal-',
      );
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final held = <HttpResponse>[];
      final renewedStarts = <int>[];
      upstream.listen((request) async {
        final match = RegExp(
          r'^bytes=(\d+)-(\d+)$',
        ).firstMatch(request.headers.value('range')!)!;
        final start = int.parse(match[1]!);
        final end = int.parse(match[2]!);
        if (request.uri.path == '/old' && start >= 65536) {
          held.add(request.response);
          return;
        }
        if (request.uri.path == '/new') renewedStarts.add(start);
        request.response.statusCode = 206;
        request.response.headers.set('etag', '"same-media"');
        request.response.headers.set(
          'content-range',
          'bytes $start-$end/$total',
        );
        request.response.contentLength = end - start + 1;
        request.response.add(
          Uint8List(end - start + 1)..fillRange(0, end - start + 1, 9),
        );
        await request.response.close();
      });
      final driver = _WarmHandoffCoreDriver();
      final backend = RillightVideoBackend(
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: temp,
        createPlayer: () async => driver,
      );
      final client = HttpClient();
      final refresh = backend.events.firstWhere(
        (e) => e.kind == VideoEventKind.sourceRefreshRequired,
      );
      try {
        await backend.open(
          VideoOpenRequest(
            sessionId: 72,
            url: Uri.parse('http://127.0.0.1:${upstream.port}/old'),
          ),
        );
        final request = await client.getUrl(driver.request!.url);
        request.headers.set('range', 'bytes=0-${total - 1}');
        final response = await request.close();
        final delivery = response.fold<int>(0, (count, bytes) {
          expect(bytes.every((byte) => byte == 9), isTrue);
          return count + bytes.length;
        });
        final event = await refresh.timeout(const Duration(seconds: 50));
        expect(event.value, 408);
        expect((await backend.diagnostics())['readAheadFailed'], false);
        await backend.refreshSourceUrl(
          Uri.parse('http://127.0.0.1:${upstream.port}/new'),
        );
        expect(await delivery.timeout(const Duration(seconds: 5)), total);
        expect(renewedStarts.first, 65536);
        final data = await backend.diagnostics();
        expect(data['invalidations'], 0);
        expect(data['sourceRenewalCount'], 1);
        expect(data['readAheadFailed'], false);
      } finally {
        client.close(force: true);
        await backend.dispose();
        for (final response in held) {
          unawaited(response.close().catchError((Object _) => response));
        }
        await upstream.close(force: true);
        await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'subtitle presentation forwards geometry and rejects stale session',
    () async {
      final driver = _CoreDriver();
      final backend = RillightVideoBackend(
        diskCacheDirectory: isolatedCache,
        settingsStore: MemoryPlayerSettingsStore(),
        createPlayer: () async => driver,
      );
      addTearDown(backend.dispose);
      await backend.open(
        VideoOpenRequest(
          sessionId: 17,
          url: Uri.parse('http://127.0.0.1:1/synthetic.mp4'),
        ),
      );
      const p = SubtitlePresentation(
        displayWidth: 360,
        displayHeight: 202.5,
        fontSize: 20,
        userScale: 1.5,
        originalAss: true,
      );
      await backend.setSubtitlePresentation(p, sessionId: 17);
      expect(driver.lastCommand, 'subtitlePresentation');
      expect(driver.lastArgs, p.toMap());
      await expectLater(
        backend.setSubtitlePresentation(p, sessionId: 16),
        throwsStateError,
      );
    },
  );

  test(
    'next episode with a warmed prefix publishes current cache and speed after seek',
    () async {
      const total = 512 * 1024;
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        final match = RegExp(
          r'^bytes=(\d+)-(\d+)$',
        ).firstMatch(request.headers.value('range')!)!;
        final start = int.parse(match[1]!);
        final end = int.parse(match[2]!);
        request.response.statusCode = 206;
        request.response.headers.set(
          'content-range',
          'bytes $start-$end/$total',
        );
        request.response.headers.set('etag', '"${request.uri.path}"');
        request.response.contentLength = end - start + 1;
        request.response.add(List.filled(end - start + 1, 9));
        await request.response.close();
      });
      final backend = RillightVideoBackend(
        diskCacheDirectory: isolatedCache,
        settingsStore: MemoryPlayerSettingsStore(),
        createPlayer: () async => _WarmHandoffCoreDriver(),
      );
      final speeds = <(int, double)>[];
      final snapshots = <BufferSnapshot>[];
      final subscription = backend.events.listen((event) {
        if (event.kind == VideoEventKind.cacheSpeed) {
          speeds.add((event.sessionId, event.value as double));
        }
        if (event.kind == VideoEventKind.bufferSnapshot) {
          snapshots.add(event.value as BufferSnapshot);
        }
      });
      Future<void> waitFor(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(condition(), isTrue);
      }

      try {
        await backend.open(
          VideoOpenRequest(
            sessionId: 1,
            url: Uri.parse('http://127.0.0.1:${upstream.port}/episode-one'),
          ),
        );
        await waitFor(
          () =>
              snapshots.any((s) => s.sessionId == 1 && s.byteCoverage != null),
        );
        await backend.open(
          VideoOpenRequest(
            sessionId: 2,
            url: Uri.parse('http://127.0.0.1:${upstream.port}/episode-two'),
            warmedPrefix: Uint8List(32768)..fillRange(0, 32768, 9),
          ),
        );
        await waitFor(
          () => snapshots.any(
            (s) =>
                s.sessionId == 2 &&
                s.byteCoverage?.ranges.any(
                      (r) => r.start == 32768 && r.end == 65536,
                    ) ==
                    true,
          ),
        );
        await backend.seek(const Duration(seconds: 3));
        await waitFor(
          () => snapshots.any(
            (s) =>
                s.sessionId == 2 &&
                s.byteCoverage?.ranges.any(
                      // The continuous producer may already have cached
                      // beyond the small seek response when diagnostics run.
                      (r) => r.start <= 131072 && r.end >= 262144,
                    ) ==
                    true,
          ),
        );
        expect(speeds.any((sample) => sample.$1 == 2 && sample.$2 > 0), isTrue);
        final current = snapshots.last;
        expect(current.sessionId, 2);
        expect(current.byteCoverage!.ranges.first.start, 32768);
      } finally {
        await subscription.cancel();
        await backend.dispose();
        await upstream.close(force: true);
      }
    },
  );
  test(
    'rejected optional audio keeps the current track and playable session',
    () async {
      final core = _RejectedAudioCoreDriver();
      final backend = RillightVideoBackend(
        diskCacheDirectory: isolatedCache,
        settingsStore: MemoryPlayerSettingsStore(),
        createPlayer: () async => core,
      );
      addTearDown(backend.dispose);
      await backend.open(
        VideoOpenRequest(
          sessionId: 81,
          url: Uri.parse('http://127.0.0.1:8765/media.mp4'),
        ),
      );
      await expectLater(
        backend.setAudioIndex(3),
        throwsA(isA<DeviceTrackRejected>()),
      );
      expect(backend.selectedAudioIndex, 2);
      expect(backend.audioTrackSupported(3), false);
      expect(core.disposed, false);
      await expectLater(
        backend.setAudioIndex(3),
        throwsA(isA<DeviceTrackRejected>()),
      );
      expect(core.attempts, 1);
      await backend.play();
      expect(backend.isPlaying, true);
      expect(backend.audioTrackSupported(3), false);
      expect(backend.lastFailure, isNull);
    },
  );
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
          expect((await backend.diagnostics())['playbackActive'], true);
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
      diskCacheDirectory: isolatedCache,
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
      diskCacheDirectory: isolatedCache,
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
      diskCacheDirectory: isolatedCache,
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
      diskCacheDirectory: isolatedCache,
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
      diskCacheDirectory: isolatedCache,
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

  test(
    'saved enhancement is applied on open and deadlines do not rewrite it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'rillight-enhancement-open-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/settings.json');
      final store = FilePlayerSettingsStore(file);
      await store.write(
        const PlayerSettings(
          frameInterpolation: FrameInterpolation.doubleRate,
          anime4k: Anime4kLevel.light,
          denoise: 40,
          sharpen: 0,
          acceptLeaveNativeDolby: false,
        ),
      );
      final before = await file.readAsString();
      final driver = _CoreDriver();
      final backend = RillightVideoBackend(
        settingsStore: store,
        diskCacheDirectory: isolatedCache,
        createPlayer: () async => driver,
      );
      addTearDown(backend.dispose);
      await backend.open(
        VideoOpenRequest(
          sessionId: 41,
          url: Uri.parse('http://127.0.0.1:1/synthetic.mp4'),
        ),
      );
      final sealed = driver.request!.url;
      expect(driver.commands, contains('enhancement'));
      expect(driver.enhancementArgs, {
        'interpolation': 2,
        'anime4k': 1,
        'superResolution': 0,
        'denoise': 40,
        'sharpen': 0,
        'acceptLeaveNativeDolby': false,
        'displayRefreshHz': currentDisplayRefreshHz(),
      });
      await backend.noteVideoFrameDeadline(met: false, monotonicUs: 0);
      await backend.noteVideoFrameDeadline(met: false, monotonicUs: 1000000);
      expect(driver.deadlineArgs, {'met': false, 'monotonicUs': 1000000});
      expect(driver.request!.url, sealed);
      expect(await file.readAsString(), before);
      final saved = await store.read();
      expect(
        saved.videoEnhancement.interpolation,
        FrameInterpolation.doubleRate,
      );
      expect(saved.videoEnhancement.anime4k, Anime4kLevel.light);
      expect(saved.toJson().containsKey('effectiveInterpolation'), isFalse);

      final defaults = _CoreDriver();
      final plainCache = await Directory(
        '${directory.path}/plain-cache',
      ).create();
      final plain = RillightVideoBackend(
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: plainCache,
        createPlayer: () async => defaults,
      );
      addTearDown(plain.dispose);
      await plain.open(
        VideoOpenRequest(
          sessionId: 42,
          url: Uri.parse('http://127.0.0.1:1/plain.mp4'),
        ),
      );
      expect(defaults.enhancementArgs, {
        'interpolation': 0,
        'anime4k': 0,
        'superResolution': 0,
        'denoise': 0,
        'sharpen': 0,
        'acceptLeaveNativeDolby': false,
        'displayRefreshHz': currentDisplayRefreshHz(),
      });
    },
  );

  test('open and apply pass the current display refresh', () async {
    var hz = 144;
    final driver = _CoreDriver();
    final backend = RillightVideoBackend(
      settingsStore: MemoryPlayerSettingsStore(),
      diskCacheDirectory: isolatedCache,
      createPlayer: () async => driver,
      readDisplayRefreshHz: () => hz,
    );
    addTearDown(backend.dispose);
    await backend.open(
      VideoOpenRequest(
        sessionId: 47,
        url: Uri.parse('http://127.0.0.1:1/refresh.mp4'),
      ),
    );
    expect(driver.enhancementArgs?['displayRefreshHz'], 144);
    hz = 30;
    await backend.applyVideoEnhancement(
      const VideoEnhancementSelection(
        interpolation: FrameInterpolation.doubleRate,
        anime4k: Anime4kLevel.off,
        superResolution: SuperResolution.off,
        denoise: 0,
        sharpen: 0,
        acceptLeaveNativeDolby: false,
      ),
    );
    expect(driver.enhancementArgs?['displayRefreshHz'], 30);
    hz = 0;
    await backend.applyVideoEnhancement(
      const VideoEnhancementSelection(
        interpolation: FrameInterpolation.doubleRate,
        anime4k: Anime4kLevel.off,
        superResolution: SuperResolution.off,
        denoise: 0,
        sharpen: 0,
        acceptLeaveNativeDolby: false,
      ),
    );
    expect(driver.enhancementArgs?['displayRefreshHz'], 0);
  });

  test('retry marks clearOverload and ordinary apply does not', () async {
    var hz = 120;
    final driver = _CoreDriver();
    final backend = RillightVideoBackend(
      settingsStore: MemoryPlayerSettingsStore(),
      diskCacheDirectory: isolatedCache,
      createPlayer: () async => driver,
      readDisplayRefreshHz: () => hz,
    );
    addTearDown(backend.dispose);
    await backend.open(
      VideoOpenRequest(
        sessionId: 48,
        url: Uri.parse('http://127.0.0.1:1/retry.mp4'),
      ),
    );
    const selection = VideoEnhancementSelection(
      interpolation: FrameInterpolation.doubleRate,
      anime4k: Anime4kLevel.light,
      superResolution: SuperResolution.off,
      denoise: 20,
      sharpen: 10,
      acceptLeaveNativeDolby: false,
    );
    await backend.applyVideoEnhancement(selection);
    expect(driver.enhancementArgs?.containsKey('clearOverload'), isFalse);
    expect(driver.enhancementArgs?['displayRefreshHz'], 120);
    hz = 50;
    await backend.applyVideoEnhancement(selection, clearOverload: true);
    expect(driver.enhancementArgs?['clearOverload'], isTrue);
    expect(driver.enhancementArgs?['displayRefreshHz'], 50);
    expect(driver.enhancementArgs?['interpolation'], 2);
    expect(driver.enhancementArgs?['anime4k'], 1);
    await backend.applyVideoEnhancement(selection);
    expect(driver.enhancementArgs?.containsKey('clearOverload'), isFalse);
    expect(driver.enhancementArgs?['displayRefreshHz'], 50);
  });

  test(
    'screen, refresh, and resume reconfigure the current enhancement',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      var hz = 144;
      var displayId = 7;
      final driver = _CoreDriver();
      final backend = RillightVideoBackend(
        settingsStore: MemoryPlayerSettingsStore(
          const PlayerSettings(
            frameInterpolation: FrameInterpolation.doubleRate,
          ),
        ),
        diskCacheDirectory: isolatedCache,
        createPlayer: () async => driver,
        readDisplayRefreshHz: () => hz,
        readDisplayId: () => displayId,
      );
      addTearDown(backend.dispose);
      await backend.open(
        VideoOpenRequest(
          sessionId: 49,
          url: Uri.parse('http://127.0.0.1:1/display.mp4'),
        ),
      );
      int enhancementCount() =>
          driver.commands.where((method) => method == 'enhancement').length;
      expect(driver.enhancementArgs?['displayRefreshHz'], 144);
      expect(driver.enhancementArgs?.containsKey('clearOverload'), isFalse);
      final opened = enhancementCount();

      WidgetsBinding.instance.handleMetricsChanged();
      await backend.debugPendingDisplayReconfigure;
      expect(enhancementCount(), opened);

      hz = 60;
      WidgetsBinding.instance.handleMetricsChanged();
      await backend.debugPendingDisplayReconfigure;
      expect(enhancementCount(), opened + 1);
      expect(driver.enhancementArgs?['displayRefreshHz'], 60);
      expect(driver.enhancementArgs?.containsKey('clearOverload'), isFalse);
      expect(driver.enhancementArgs?['interpolation'], 2);

      WidgetsBinding.instance.handleMetricsChanged();
      await backend.debugPendingDisplayReconfigure;
      expect(enhancementCount(), opened + 1);

      displayId = 8;
      WidgetsBinding.instance.handleMetricsChanged();
      await backend.debugPendingDisplayReconfigure;
      expect(enhancementCount(), opened + 2);
      expect(driver.enhancementArgs?['displayRefreshHz'], 60);

      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await backend.debugPendingDisplayReconfigure;
      expect(enhancementCount(), opened + 3);
      expect(driver.enhancementArgs?['displayRefreshHz'], 60);

      hz = 0;
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await backend.debugPendingDisplayReconfigure;
      expect(enhancementCount(), opened + 4);
      expect(driver.enhancementArgs?['displayRefreshHz'], 0);
      expect(driver.enhancementArgs?['interpolation'], 2);
      expect(driver.enhancementArgs?.containsKey('clearOverload'), isFalse);

      final afterResume = enhancementCount();
      await backend.stop();
      hz = 144;
      displayId = 9;
      WidgetsBinding.instance.handleMetricsChanged();
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await backend.debugPendingDisplayReconfigure;
      expect(enhancementCount(), afterResume);
    },
  );

  test('display refresh rounds nominal rates and drops unknown ones', () {
    expect(normalizeDisplayRefreshHz(59.94), 60);
    expect(normalizeDisplayRefreshHz(47.95), 48);
    expect(normalizeDisplayRefreshHz(60), 60);
    expect(normalizeDisplayRefreshHz(0), 0);
    expect(normalizeDisplayRefreshHz(-1), 0);
    expect(normalizeDisplayRefreshHz(double.nan), 0);
    expect(normalizeDisplayRefreshHz(double.infinity), 0);
    expect(normalizeDisplayRefreshHz(1000), 1000);
    expect(normalizeDisplayRefreshHz(1001), 0);
    expect(currentDisplayRefreshHz(), greaterThan(0));
  });

  test(
    'later core output samples replace kind and tier without moving playback',
    () async {
      final driver = _CoreDriver();
      final backend = RillightVideoBackend(
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: isolatedCache,
        createPlayer: () async => driver,
      );
      addTearDown(backend.dispose);
      await backend.open(
        VideoOpenRequest(
          sessionId: 43,
          url: Uri.parse('http://127.0.0.1:1/output.mp4'),
          start: const Duration(seconds: 4),
        ),
      );
      final position = backend.position;
      driver.emit('outputStatus', {
        'dolbyVisionProfile': 5,
        'videoOutputKind': 3,
        'audioDelivery': 4,
        'audioChannels': 8,
        'audioAtmos': 1,
        'outputColorSpace': 'scRGB',
        'hdrDisplayActive': true,
        'hdrOutput': true,
        'requestedInterpolation': 2,
        'effectiveInterpolation': 2,
        'reasonInterpolation': 1,
      });
      await Future<void>.delayed(Duration.zero);
      expect(backend.outputStatus.videoOutputKind, 3);
      expect(backend.outputStatus.outputColorSpace, 'scRGB');
      expect(backend.outputStatus.hdrDisplayActive, isTrue);
      driver.emit('outputStatus', {
        'dolbyVisionProfile': 5,
        'videoOutputKind': 1,
        'audioDelivery': 2,
        'audioChannels': 2,
        'audioAtmos': 0,
        'requestedInterpolation': 2,
        'effectiveInterpolation': 0,
        'reasonInterpolation': 4,
      });
      await Future<void>.delayed(Duration.zero);
      expect(backend.outputStatus.videoOutputKind, 1);
      expect(backend.outputStatus.audioDelivery, 2);
      expect(backend.outputStatus.effectiveInterpolation, 0);
      expect(backend.outputStatus.reasonInterpolation, 4);
      expect(backend.outputStatus.outputColorSpace, 'scRGB');
      expect(backend.outputStatus.hdrDisplayActive, isTrue);
      expect(backend.position, position);
      expect(backend.isPlaying, isFalse);
    },
  );

  test('enhancement waits for the frame that rewrites video kind', () async {
    final driver = _FrameOutputCoreDriver();
    final backend = RillightVideoBackend(
      settingsStore: MemoryPlayerSettingsStore(),
      diskCacheDirectory: isolatedCache,
      createPlayer: () async => driver,
    );
    addTearDown(backend.dispose);
    await backend.open(
      VideoOpenRequest(
        sessionId: 44,
        url: Uri.parse('http://127.0.0.1:1/frame.mp4'),
      ),
    );
    expect(backend.outputStatus.videoOutputKind, 3);
    final position = backend.position;
    await backend.applyVideoEnhancement(
      const VideoEnhancementSelection(
        interpolation: FrameInterpolation.off,
        anime4k: Anime4kLevel.off,
        superResolution: SuperResolution.off,
        denoise: 0,
        sharpen: 0,
        acceptLeaveNativeDolby: false,
      ),
    );
    expect(backend.outputStatus.videoOutputKind, 1);
    expect(backend.outputStatus.audioDelivery, 3);
    expect(backend.outputStatus.effectiveInterpolation, 0);
    expect(backend.outputStatus.reasonInterpolation, 4);
    expect(backend.outputStatus.outputColorSpace, 'scRGB');
    expect(backend.position, position);
    expect(driver.commands.where((method) => method == 'outputStatus'), [
      'outputStatus',
    ]);

    driver.emit('playing', true);
    await backend.applyVideoEnhancement(
      const VideoEnhancementSelection(
        interpolation: FrameInterpolation.doubleRate,
        anime4k: Anime4kLevel.off,
        superResolution: SuperResolution.off,
        denoise: 0,
        sharpen: 0,
        acceptLeaveNativeDolby: true,
      ),
    );
    expect(backend.isPlaying, isTrue);
    expect(backend.outputStatus.videoOutputKind, 3);
    for (
      var attempt = 0;
      attempt < 8 && backend.outputStatus.videoOutputKind != 1;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(backend.outputStatus.videoOutputKind, 1);
    expect(backend.outputStatus.reasonInterpolation, 4);
    expect(backend.position, position);
  });

  test('stale output refresh does not cover a newer frame sample', () async {
    final driver = _StaleOutputCoreDriver();
    final backend = RillightVideoBackend(
      settingsStore: MemoryPlayerSettingsStore(),
      diskCacheDirectory: isolatedCache,
      createPlayer: () async => driver,
    );
    addTearDown(backend.dispose);
    await backend.open(
      VideoOpenRequest(
        sessionId: 45,
        url: Uri.parse('http://127.0.0.1:1/stale.mp4'),
      ),
    );
    await backend.applyVideoEnhancement(
      const VideoEnhancementSelection(
        interpolation: FrameInterpolation.off,
        anime4k: Anime4kLevel.off,
        superResolution: SuperResolution.off,
        denoise: 0,
        sharpen: 0,
        acceptLeaveNativeDolby: false,
      ),
    );
    expect(backend.outputStatus.videoOutputKind, 1);
    expect(backend.outputStatus.audioDelivery, 3);
    expect(backend.outputStatus.effectiveInterpolation, 0);
    expect(backend.outputStatus.reasonInterpolation, 4);
    expect(backend.outputStatus.audioAtmos, isFalse);
    expect(backend.outputStatus.outputColorSpace, 'scRGB');
    expect(backend.outputStatus.hdrDisplayActive, isTrue);
    expect(backend.position, const Duration(milliseconds: 2400));
  });

  test('playing follow-up waits for output fields, not position', () async {
    final driver = _LateFrameCoreDriver();
    final backend = RillightVideoBackend(
      settingsStore: MemoryPlayerSettingsStore(),
      diskCacheDirectory: isolatedCache,
      createPlayer: () async => driver,
    );
    addTearDown(backend.dispose);
    await backend.open(
      VideoOpenRequest(
        sessionId: 46,
        url: Uri.parse('http://127.0.0.1:1/late-frame.mp4'),
      ),
    );
    driver.emit('playing', true);
    await backend.applyVideoEnhancement(
      const VideoEnhancementSelection(
        interpolation: FrameInterpolation.off,
        anime4k: Anime4kLevel.off,
        superResolution: SuperResolution.off,
        denoise: 0,
        sharpen: 0,
        acceptLeaveNativeDolby: true,
      ),
    );
    expect(backend.isPlaying, isTrue);
    expect(backend.outputStatus.videoOutputKind, 3);
    for (
      var attempt = 0;
      attempt < 20 && backend.outputStatus.videoOutputKind != 1;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(driver.outputReads, greaterThanOrEqualTo(3));
    expect(backend.outputStatus.videoOutputKind, 1);
    expect(backend.outputStatus.audioDelivery, 3);
    expect(backend.outputStatus.effectiveInterpolation, 0);
    expect(backend.outputStatus.reasonInterpolation, 4);
  });
}
