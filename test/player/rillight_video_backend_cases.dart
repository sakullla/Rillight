import '../helpers/case_shard.dart';
import '../helpers/temporary_directory.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/buffer_snapshot.dart';
import 'package:rillight/player/cache/cache_limits.dart';
import 'package:rillight/player/rillight_video_backend.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/playback_recovery_coordinator.dart';
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
  _WarmHandoffCoreDriver({this.initialRange = 'bytes=0-65535'});
  final String initialRange;
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
    await _read(initialRange);
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

class _DiagnosticCoreDriver extends _CoreDriver {
  _DiagnosticCoreDriver(
    this.source, {
    this.failOpen = false,
    this.failSnapshot = false,
  });

  final String source;
  final bool failOpen;
  final bool failSnapshot;
  final snapshotRead = Completer<void>();
  Completer<Map<String, dynamic>>? snapshotGate;
  Map<String, dynamic> get diagnostics => {
    'decodeDiagnostics': 'software $source',
    'sourceDiagnostics':
        'format=matroska url=$source${failOpen ? " err=-5" : ""}',
  };

  @override
  Future<Map<String, dynamic>> open(CorePlayerOpen value) async {
    final result = await super.open(value);
    if (failOpen) throw StateError('Core media open failed (-5)');
    return {...result, ...diagnostics};
  }

  @override
  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    if (method != 'outputStatus') return super.command(method, args);
    expect(disposed, isFalse, reason: 'Failure snapshot must precede teardown');
    if (!snapshotRead.isCompleted) snapshotRead.complete();
    if (failSnapshot) throw StateError('Snapshot unavailable');
    return snapshotGate == null ? diagnostics : await snapshotGate!.future;
  }
}

class _ExpiredHlsCoreDriver extends _CoreDriver {
  _ExpiredHlsCoreDriver({this.failImmediately = false});
  final bool failImmediately;
  final expired = Completer<void>();
  final releaseOpen = Completer<void>();

  @override
  Future<Map<String, dynamic>> open(CorePlayerOpen value) async {
    request = value;
    final client = HttpClient();
    try {
      final manifest = await (await (await client.getUrl(
        value.url,
      )).close()).transform(utf8.decoder).join();
      final segment = Uri.parse(
        manifest.split('\n').firstWhere((line) => line.startsWith('http')),
      );
      final response = await (await client.getUrl(segment)).close();
      await response.drain<void>();
      expect(response.statusCode, anyOf(404, 410));
      expired.complete();
      if (failImmediately) throw StateError('Expired first segment');
      await releaseOpen.future;
      return await super.open(value);
    } finally {
      client.close(force: true);
    }
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
  cases.test('remote Plex selection IDs map to negotiated output indices in both directions', () async {
    final temp = await Directory.systemTemp.createTemp(
      'provider-output-indices-',
    );
    final driver = _CoreDriver();
    final backend = RillightVideoBackend(
      mediaHeaderTimeout: const Duration(milliseconds: 800),
      sourceStallTimeout: const Duration(milliseconds: 150),
      waitForRetry: _retryImmediately,
      createPlayer: () async => driver,
      diskCacheDirectory: temp,
      settingsStore: MemoryPlayerSettingsStore(),
    );
    try {
      await backend.open(
        VideoOpenRequest(
          url: Uri.parse('http://127.0.0.1/movie'),
          sessionId: 1,
          mediaStreams: const [
            MediaStreamInfo(
              index: 721,
              playbackIndex: 2,
              type: 'Audio',
              language: 'eng',
            ),
          ],
        ),
      );
      expect(driver.request!.streams.single.index, 2);
      expect(backend.selectedAudioIndex, 721);
      expect(backend.audioTrackSupported(721), true);
      await backend.setAudioIndex(721);
      expect(driver.lastArgs['index'], 2);
      expect(backend.selectedAudioIndex, 721);
    } finally {
      await backend.dispose();
      await deleteTemporaryDirectory(temp);
    }
  });

  late Directory isolatedCache;
  setUp(() async {
    isolatedCache = await Directory.systemTemp.createTemp(
      'rillight-backend-test-',
    );
    // Never join the real player's shared quota while running unit tests.
    // A test's default 2 GiB budget can evict an active 8 GiB session.
    addTearDown(() => deleteTemporaryDirectory(isolatedCache));
  });
  cases.test(
    'Android prefetch follows saved disk budget across opens',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final settings = MemoryPlayerSettingsStore();
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
        settingsStore: settings,
        diskCacheDirectory: isolatedCache,
        createPlayer: () async => _CoreDriver(),
      );
      addTearDown(backend.dispose);
      for (final mib in [2048, 512, 4096]) {
        await settings.write(PlayerSettings(diskCacheLimitMiB: mib));
        await backend.open(
          VideoOpenRequest(
            sessionId: mib,
            url: Uri.parse('http://127.0.0.1:8765/movie'),
          ),
        );
        final data = await backend.diagnostics();
        expect(data['continuousTransfers'], isTrue);
        expect(data['configuredReadAheadBytes'], mib * 1024 * 1024);
        expect(data['diskSessionLimitBytes'], mib * 1024 * 1024);
        expect(data['memoryLimitBytes'], 8 * 1024 * 1024);
        expect(data['pendingLimitBytes'], defaultCachePendingBytes);
      }
    },
  );

  cases.test(
    'startup output hold keeps read-ahead active until settings are restored',
    () async {
      final driver = _CoreDriver();
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: isolatedCache,
        createPlayer: () async => driver,
      );
      addTearDown(backend.dispose);
      await backend.open(
        VideoOpenRequest(
          sessionId: 31,
          url: Uri.parse('http://127.0.0.1:8765/movie'),
          holdPlaybackForSettings: true,
        ),
      );
      expect(driver.request!.paused, isTrue);
      expect((await backend.diagnostics())['playbackActive'], isTrue);
      await backend.setVolume(25);
      await backend.setRate(1.25);
      await backend.play();
      expect(driver.commands, containsAllInOrder(['volume', 'rate', 'play']));
      expect(backend.isPlaying, isTrue);
      await backend.pause();
      expect((await backend.diagnostics())['playbackActive'], isFalse);
    },
  );

  for (final interrupted in [false, true]) {
    cases.test(
      'network failure delegates recovery without reopening interruption=$interrupted',
      () async {
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        upstream.listen((request) async {
          request.response.statusCode = HttpStatus.serviceUnavailable;
          await request.response.close();
        });
        final first = _CoreDriver();
        final recovered = _CoreDriver();
        var creates = 0;
        final backend = RillightVideoBackend(
          mediaHeaderTimeout: const Duration(milliseconds: 800),
          sourceStallTimeout: const Duration(milliseconds: 150),
          waitForRetry: _retryImmediately,
          settingsStore: MemoryPlayerSettingsStore(),
          diskCacheDirectory: isolatedCache,
          createPlayer: () async => creates++ == 0 ? first : recovered,
        );
        final client = HttpClient();
        addTearDown(() async {
          client.close(force: true);
          await backend.dispose();
          await upstream.close(force: true);
        });
        await backend.open(
          VideoOpenRequest(
            sessionId: 32,
            url: Uri.parse('http://127.0.0.1:${upstream.port}/movie'),
            holdPlaybackForSettings: true,
          ),
        );
        await backend.setVolume(25);
        await backend.setRate(1.25);
        await backend.play();
        // A failed demuxer request supplies the real transport failure state.
        final response = await (await client.headUrl(first.request!.url))
            .close();
        expect(response.statusCode, HttpStatus.serviceUnavailable);
        await response.drain<void>();
        final finished = backend.events
            .firstWhere((event) => event.kind == VideoEventKind.error)
            .timeout(const Duration(seconds: 2));
        if (interrupted) first.emit('interruption', 'audioFocus');
        first.emit('error', 'synthetic network failure');
        expect((await finished).value, 'synthetic network failure');
        expect(creates, 1);
        expect(recovered.request, isNull);
        expect(recovered.commands, isEmpty);
      },
    );
  }

  cases.test(
    'slow recovery headers do not trigger premature startup source renewal',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      upstream.listen((request) async {
        if (++requests == 1) {
          request.response.statusCode = 502;
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 310));
          request.response.contentLength = 8;
          // Keep headers and body in separate diagnostic ticks: receiving
          // valid slow headers is progress even before the first body byte.
          final socket = await request.response.detachSocket();
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 150));
          socket.add(List.filled(8, 9));
          await socket.close();
          return;
        }
        await request.response.close();
      });
      final driver = _PendingOpenCoreDriver()..releaseOpen.complete();
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
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
        expect(renewals, isEmpty, reason: 'Valid slow headers must not renew');
      } finally {
        await subscription.cancel();
        await backend.dispose();
        await upstream.close(force: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );

  for (final failImmediately in [false, true]) {
    cases.test(
      'expired HLS segments renew each initial transcode open immediateFailure=$failImmediately',
      () async {
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var status = 404;
        var segmentRequests = 0;
        upstream.listen((request) async {
          if (request.uri.path == '/index.m3u8') {
            request.response.headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            );
            request.response.write(
              '#EXTM3U\n#EXTINF:2,\na.ts\n#EXT-X-ENDLIST\n',
            );
          } else {
            segmentRequests++;
            request.response.statusCode = status;
          }
          await request.response.close();
        });
        final drivers = <_ExpiredHlsCoreDriver>[];
        final backend = RillightVideoBackend(
          mediaHeaderTimeout: const Duration(milliseconds: 800),
          sourceStallTimeout: const Duration(milliseconds: 150),
          waitForRetry: _retryImmediately,
          diskCacheDirectory: isolatedCache,
          settingsStore: MemoryPlayerSettingsStore(),
          createPlayer: () async {
            final driver = _ExpiredHlsCoreDriver(
              failImmediately: failImmediately,
            );
            drivers.add(driver);
            return driver;
          },
        );
        final renewals = <VideoBackendEvent>[];
        final subscription = backend.events.listen((event) {
          if (event.kind == VideoEventKind.sourceRefreshRequired) {
            renewals.add(event);
          }
        });
        try {
          for (final session in [1, 2]) {
            status = session == 1 ? 404 : 410;
            final opening = backend.open(
              VideoOpenRequest(
                sessionId: session,
                url: Uri.parse('http://127.0.0.1:${upstream.port}/index.m3u8'),
                playMethod: PlayMethod.transcode,
              ),
            );
            final opened = expectLater(
              opening,
              failImmediately ? throwsStateError : completes,
            );
            try {
              final deadline = DateTime.now().add(const Duration(seconds: 10));
              while (renewals.length < session &&
                  DateTime.now().isBefore(deadline)) {
                await Future<void>.delayed(const Duration(milliseconds: 20));
              }
              expect(drivers.last.expired.isCompleted, isTrue);
              expect(renewals, hasLength(session));
              expect(renewals.last.sessionId, session);
              expect(renewals.last.value, 404);
              expect((await backend.diagnostics())['openPhase'], 'openingCore');
              await Future<void>.delayed(const Duration(milliseconds: 300));
              expect(renewals, hasLength(session));
            } finally {
              drivers.last.releaseOpen.complete();
              await opened;
            }
          }
          expect(segmentRequests, 12);
        } finally {
          await subscription.cancel();
          await backend.dispose();
          await upstream.close(force: true);
        }
      },
    );
  }
  cases.test(
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
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
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

  cases.test(
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
        final match = RegExp(r'^bytes=(\d+)-(\d+)$')
            .firstMatch(request.headers.value('range')!)!;
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
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
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
        await deleteTemporaryDirectory(temp);
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  cases.test(
    'subtitle presentation forwards geometry and rejects stale session',
    () async {
      final driver = _CoreDriver();
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
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

  cases.test('next episode with a warmed prefix publishes current cache and speed after seek', () async {
    const total = 512 * 1024;
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      final match = RegExp(r'^bytes=(\d+)-(\d+)$')
          .firstMatch(request.headers.value('range')!)!;
      final start = int.parse(match[1]!);
      final end = int.parse(match[2]!);
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes $start-$end/$total');
      request.response.headers.set('etag', '"${request.uri.path}"');
      request.response.contentLength = end - start + 1;
      request.response.add(List.filled(end - start + 1, 9));
      await request.response.close();
    });
    final backend = RillightVideoBackend(
      mediaHeaderTimeout: const Duration(milliseconds: 800),
      sourceStallTimeout: const Duration(milliseconds: 150),
      waitForRetry: _retryImmediately,
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
        () => snapshots.any((s) => s.sessionId == 1 && s.byteCoverage != null),
      );
      await backend.open(
        VideoOpenRequest(
          sessionId: 2,
          url: Uri.parse('http://127.0.0.1:${upstream.port}/episode-two'),
          warmedPrefix: Uint8List(32768)..fillRange(0, 32768, 9),
          warmedPrefixEtag: '"/episode-two"',
          warmedPrefixTotalBytes: total,
        ),
      );
      await waitFor(
        () => snapshots.any(
          (s) =>
              s.sessionId == 2 &&
              s.byteCoverage?.ranges.any(
                    (r) => r.start == 0 && r.end >= 65536,
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
      expect(current.byteCoverage!.ranges.first.start, 0);
    } finally {
      await subscription.cancel();
      await backend.dispose();
      await upstream.close(force: true);
    }
  });
  cases.test(
    'growing cache scans less often than download speed updates',
    () async {
      const block = 64 * 1024;
      const total = 32 * 1024 * 1024;
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        final match = RegExp(r'^bytes=(\d+)-(\d+)$')
            .firstMatch(request.headers.value('range')!)!;
        final start = int.parse(match[1]!);
        final end = int.parse(match[2]!);
        request.response.statusCode = 206;
        request.response.headers.set(
          'content-range',
          'bytes $start-$end/$total',
        );
        request.response.headers.set('etag', '"growing-cache"');
        request.response.contentLength = end - start + 1;
        request.response.add(Uint8List(end - start + 1));
        await request.response.close();
      });
      final driver = _WarmHandoffCoreDriver();
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
        diskCacheDirectory: isolatedCache,
        settingsStore: MemoryPlayerSettingsStore(),
        createPlayer: () async => driver,
      );
      var speedUpdates = 0;
      final subscription = backend.events.listen((event) {
        if (event.kind == VideoEventKind.cacheSpeed) speedUpdates++;
      });
      try {
        await backend.open(
          VideoOpenRequest(
            sessionId: 1,
            url: Uri.parse('http://127.0.0.1:${upstream.port}/growing'),
          ),
        );
        // Keep the read-ahead worker paused so each synthetic native read adds
        // bytes rather than letting a fast localhost producer fill the fixture.
        await backend.pause();
        final before =
            (await backend.diagnostics())['diskIntegrityScans'] as int? ?? 0;
        for (var i = 1; i <= 10; i++) {
          await driver._read('bytes=${i * block}-${(i + 1) * block - 1}');
          await Future<void>.delayed(const Duration(milliseconds: 160));
        }
        final data = await backend.diagnostics();
        final scans = (data['diskIntegrityScans'] as int? ?? 0) - before;
        expect(scans, inInclusiveRange(1, 4));
        expect(speedUpdates, greaterThan(scans));
        expect(backend.bufferSnapshot.byteCoverage?.ranges, isNotEmpty);
      } finally {
        await subscription.cancel();
        await backend.dispose();
        await upstream.close(force: true);
      }
    },
  );
  cases.test(
    'rejected optional audio keeps the current track and playable session',
    () async {
      final core = _RejectedAudioCoreDriver();
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
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
  for (final status in [
    HttpStatus.ok,
    HttpStatus.unauthorized,
    HttpStatus.forbidden,
    HttpStatus.tooManyRequests,
  ]) {
    cases.test(
      'transport reports HTTP $status before the core finishes opening',
      () async {
        final temp = await Directory.systemTemp.createTemp('rillight-opening-');
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        String? receivedUa;
        upstream.listen((request) async {
          receivedUa = request.headers.value('user-agent');
          request.response.statusCode = status;
          if (status == 429) request.response.headers.set('retry-after', '90');
          request.response.add(List<int>.filled(1024, 7));
          await request.response.close();
        });
        final driver = _PendingOpenCoreDriver();
        final backend = RillightVideoBackend(
          mediaHeaderTimeout: const Duration(milliseconds: 800),
          sourceStallTimeout: const Duration(milliseconds: 150),
          waitForRetry: _retryImmediately,
          settingsStore: MemoryPlayerSettingsStore(),
          diskCacheDirectory: temp,
          createPlayer: () async => driver,
        );
        final reported = backend.events.firstWhere(
          (event) => status == HttpStatus.ok
              ? event.kind == VideoEventKind.cacheSpeed &&
                    (event.value as num) > 0
              : status == 401
              ? event.kind == VideoEventKind.authenticationRequired &&
                    event.value == status
              : event.kind == VideoEventKind.error &&
                    event.value is PlaybackRecoveryFailure &&
                    (event.value as PlaybackRecoveryFailure).kind ==
                        (status == 403
                            ? PlaybackRecoveryFailureKind.forbidden
                            : PlaybackRecoveryFailureKind.rateLimited),
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
          await deleteTemporaryDirectory(temp);
        }
      },
    );
  }
  cases.test(
    'session reset clears stale cache speed before open failure',
    () async {
      final core = _FailingCoreDriver(
        PlatformException(
          code: 'playback',
          message: 'Core rejected media open',
        ),
      );
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
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
    },
  );

  for (final previousSource in [false, true]) {
    for (final snapshotAvailable in [false, true]) {
      cases.test(
        'failed open retains only current diagnostics previous=$previousSource snapshot=$snapshotAvailable',
        () async {
          final first = _DiagnosticCoreDriver('source-a');
          final failed = _DiagnosticCoreDriver(
            'source-b',
            failOpen: true,
            failSnapshot: !snapshotAvailable,
          );
          final players = [if (previousSource) first, failed];
          final backend = RillightVideoBackend(
            mediaHeaderTimeout: const Duration(milliseconds: 800),
            sourceStallTimeout: const Duration(milliseconds: 150),
            waitForRetry: _retryImmediately,
            diskCacheDirectory: isolatedCache,
            settingsStore: MemoryPlayerSettingsStore(),
            createPlayer: () async => players.removeAt(0),
          );
          addTearDown(backend.dispose);
          if (previousSource) {
            await backend.open(
              VideoOpenRequest(
                sessionId: 1,
                url: Uri.parse('http://127.0.0.1:8765/a.mkv'),
              ),
            );
            expect(await backend.failureContext(), contains('source-a'));
          }
          await expectLater(
            backend.open(
              VideoOpenRequest(
                sessionId: 2,
                url: Uri.parse('http://127.0.0.1:8765/b.mkv'),
              ),
            ),
            throwsStateError,
          );
          expect(failed.snapshotRead.isCompleted, isTrue);
          expect(failed.disposed, isTrue);
          final context = await backend.failureContext();
          expect(
            context,
            snapshotAvailable ? contains('source-b err=-5') : isNull,
          );
          expect(
            (await backend.diagnostics())['coreDecodeDiagnostics'],
            snapshotAvailable ? 'software source-b' : '',
          );
        },
      );
    }
  }

  cases.test(
    'late failure snapshot cannot overwrite or stop the next open',
    () async {
      final failed = _DiagnosticCoreDriver('source-a', failOpen: true)
        ..snapshotGate = Completer<Map<String, dynamic>>();
      final next = _DiagnosticCoreDriver('source-b');
      final players = [failed, next];
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
        diskCacheDirectory: isolatedCache,
        settingsStore: MemoryPlayerSettingsStore(),
        createPlayer: () async => players.removeAt(0),
      );
      addTearDown(backend.dispose);
      final opening = expectLater(
        backend.open(
          VideoOpenRequest(
            sessionId: 1,
            url: Uri.parse('http://127.0.0.1:8765/a.mkv'),
          ),
        ),
        throwsStateError,
      );
      await failed.snapshotRead.future;
      await backend.open(
        VideoOpenRequest(
          sessionId: 2,
          url: Uri.parse('http://127.0.0.1:8765/b.mkv'),
        ),
      );
      failed.snapshotGate!.complete(failed.diagnostics);
      await opening;
      expect(next.disposed, isFalse);
      expect(await backend.failureContext(), contains('source-b'));
      expect(
        (await backend.diagnostics())['coreDecodeDiagnostics'],
        'software source-b',
      );
    },
  );

  cases.test('probe diagnostics expose only a numeric core failure', () async {
    final core = _FailingCoreDriver(
      PlatformException(
        code: 'playback',
        message: 'FFmpeg core error -5 signed_url=SECRET',
      ),
    );
    final backend = RillightVideoBackend(
      mediaHeaderTimeout: const Duration(milliseconds: 800),
      sourceStallTimeout: const Duration(milliseconds: 150),
      waitForRetry: _retryImmediately,
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

  cases.test(
    'probe diagnostics classify an Android first frame timeout',
    () async {
      final core = _FailingCoreDriver(
        PlatformException(
          code: 'playback',
          message: 'Media ready / first frame timed out',
        ),
      );
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
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
    },
  );

  cases.test(
    'probe diagnostics classify a desktop first frame timeout',
    () async {
      final core = _FailingCoreDriver(
        TimeoutException('Core did not render the first frame'),
      );
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
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
    },
  );

  cases.test(
    'container track IDs follow confirmed native audio changes',
    () async {
      final core = _TrackIdCoreDriver();
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
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
    },
  );

  cases.test(
    'same-session reopen clears track cache before old core stops',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'rillight-core-reopen-',
      );
      final first = _SlowDisposeCoreDriver();
      final second = _CoreDriver();
      var creates = 0;
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: temp,
        createPlayer: () async => creates++ == 0 ? first : second,
      );
      addTearDown(() async {
        if (!first.releaseDispose.isCompleted) first.releaseDispose.complete();
        await backend.dispose();
        await deleteTemporaryDirectory(temp);
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

  cases.test(
    'ready lock wake retains the decoder and rebinds event identity',
    () async {
      final driver = _CoreDriver();
      var creates = 0;
      final backend = RillightVideoBackend(
        diskCacheDirectory: isolatedCache,
        settingsStore: MemoryPlayerSettingsStore(),
        createPlayer: () async {
          creates++;
          return driver;
        },
      );
      addTearDown(backend.dispose);
      Future<void> open(int session) => backend.open(
        VideoOpenRequest(
          sessionId: session,
          cacheIdentity: 'one-video',
          url: Uri.parse('http://127.0.0.1:9/video'),
          startPaused: session > 1,
          start: session == 1 ? Duration.zero : const Duration(seconds: 12),
        ),
      );
      await open(1);
      final positioned = backend.events.firstWhere(
        (e) => e.kind == VideoEventKind.position,
      );
      driver.emit('position', 12000);
      await positioned;
      final nativeSession = driver.request!.session;
      await backend.suspend();
      expect(driver.disposed, isFalse);
      expect((await backend.diagnostics())['nativeRetained'], isTrue);
      await open(2);
      expect(creates, 1);
      expect(driver.request!.session, nativeSession);
      expect(backend.position, const Duration(seconds: 12));
      expect(backend.isPlaying, isFalse);
      final resumedEvent = backend.events.firstWhere(
        (e) => e.kind == VideoEventKind.position,
      );
      await backend.play();
      driver.emit('position', 13000);
      expect((await resumedEvent).sessionId, 2);
      await backend.stop();
      expect(driver.disposed, isTrue);
      expect((await backend.diagnostics())['transportAttached'], isFalse);
    },
  );

  for (final tagged in [true, false]) {
    cases.test(
      'native lock wake renews the URL and preserves cached bytes tagged=$tagged',
      () async {
        const total = 64 * 1024 * 1024;
        var expired = false;
        final tokens = <String?>[];
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        upstream.listen((request) async {
          final token = request.uri.queryParameters['token'];
          tokens.add(token);
          if (expired && token == 'old') {
            request.response.statusCode = HttpStatus.forbidden;
          } else {
            final match = RegExp(r'^bytes=(\d+)-(\d+)$')
                .firstMatch(request.headers.value('range')!)!;
            final start = int.parse(match[1]!);
            final end = int.parse(match[2]!).clamp(start, total - 1);
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              'content-range',
              'bytes $start-$end/$total',
            );
            if (tagged) request.response.headers.set('etag', '"same-video"');
            request.response.contentLength = end - start + 1;
            request.response.add(List.filled(end - start + 1, 9));
          }
          await request.response.close();
        });
        final driver = _CoreDriver();
        var creates = 0;
        final backend = RillightVideoBackend(
          diskCacheDirectory: isolatedCache,
          settingsStore: MemoryPlayerSettingsStore(),
          createPlayer: () async {
            creates++;
            return driver;
          },
        );
        final client = HttpClient();
        addTearDown(() async {
          client.close(force: true);
          await backend.dispose();
          await upstream.close(force: true);
        });
        Future<void> open(int session) => backend.open(
          VideoOpenRequest(
            sessionId: session,
            cacheIdentity: 'same-account/video/part',
            url: Uri.parse(
              'http://127.0.0.1:${upstream.port}/video?token=${session == 1 ? 'old' : 'new'}',
            ),
            startPaused: true,
            start: const Duration(seconds: 12),
          ),
        );
        Future<void> read(int start, int end) async {
          final request = await client.getUrl(driver.request!.url);
          request.headers.set('range', 'bytes=$start-$end');
          final response = await request.close();
          expect(response.statusCode, HttpStatus.partialContent);
          final length = await response.fold<int>(0, (count, bytes) {
            expect(bytes.every((byte) => byte == 9), isTrue);
            return count + bytes.length;
          });
          expect(length, end - start + 1);
        }

        await open(1);
        // Exceed the small-prefix cache to exercise retained response bytes.
        await read(0, 2 * 1024 * 1024 - 1);
        final nativeRequest = driver.request;
        await backend.suspend();
        expired = true;
        final previousRequests = tokens.length;
        await open(2);
        expect(creates, 1);
        expect(driver.request, same(nativeRequest));
        expect(driver.disposed, isFalse);
        expect(backend.position, const Duration(seconds: 12));
        expect(backend.isPlaying, isFalse);
        await read(0, 2 * 1024 * 1024 - 1);
        expect(tokens, hasLength(previousRequests));
        expect((await backend.diagnostics())['memoryHitBytes'], greaterThan(0));
        await read(total - 65536, total - 1);
        expect(tokens.skip(previousRequests), isNotEmpty);
        expect(tokens.skip(previousRequests), everyElement('new'));
      },
    );

    cases.test(
      'suspend retains downloaded bytes across paused reopen tagged=$tagged',
      () async {
        const total = 4 * 1024 * 1024;
        var offline = false;
        var requestsWhileOffline = 0;
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        upstream.listen((request) async {
          if (offline) {
            requestsWhileOffline++;
            request.response.statusCode = 503;
          } else {
            final match = RegExp(r'^bytes=(\d+)-(\d+)$')
                .firstMatch(request.headers.value('range')!)!;
            final start = int.parse(match[1]!);
            final end = int.parse(match[2]!);
            request.response.statusCode = 206;
            request.response.headers.set(
              'content-range',
              'bytes $start-$end/$total',
            );
            if (tagged) request.response.headers.set('etag', '"same-video"');
            request.response.contentLength = end - start + 1;
            request.response.add(List.filled(end - start + 1, 9));
          }
          await request.response.close();
        });
        final drivers = <_WarmHandoffCoreDriver>[];
        final backend = RillightVideoBackend(
          diskCacheDirectory: isolatedCache,
          settingsStore: MemoryPlayerSettingsStore(),
          createPlayer: () async {
            final driver = _WarmHandoffCoreDriver(
              initialRange: 'bytes=0-2097151',
            );
            drivers.add(driver);
            return driver;
          },
        );
        addTearDown(() async {
          await backend.dispose();
          await upstream.close(force: true);
        });
        Future<void> open(int session) => backend.open(
          VideoOpenRequest(
            sessionId: session,
            cacheIdentity: 'account/item/version/part',
            url: Uri.parse(
              'http://127.0.0.1:${upstream.port}/video?session=$session',
            ),
            start: Duration(seconds: session == 1 ? 0 : 12),
            startPaused: session != 1,
          ),
        );
        await open(1);
        final route = drivers.single.request!.url;
        await backend.suspend();
        await backend
            .suspend(); // Native and Flutter lifecycle can both signal pause.
        expect(drivers.single.disposed, isFalse);
        final suspended = await backend.diagnostics();
        expect(suspended['transportAttached'], isTrue);
        expect(suspended['memoryBytes'], greaterThan(0));
        offline = true;
        await open(2).timeout(const Duration(seconds: 5));
        expect(drivers.last.request!.url, route);
        expect(drivers.last.request!.start, const Duration(seconds: 12));
        expect(drivers.last.request!.paused, isTrue);
        expect(
          requestsWhileOffline,
          0,
          reason: 'The cached prefix must play without downloading again',
        );
        expect((await backend.diagnostics())['memoryHitBytes'], greaterThan(0));
        await backend.suspend();
        await backend.stop();
        expect((await backend.diagnostics())['transportAttached'], isFalse);
        expect(backend.bufferSnapshot.unknownReason, 'stopped');
      },
    );
  }

  for (final change in ['source', 'credentials', 'dynamic', 'stop']) {
    cases.test('suspended cache is not reused after $change changes', () async {
      final drivers = <_CoreDriver>[];
      final backend = RillightVideoBackend(
        diskCacheDirectory: isolatedCache,
        settingsStore: MemoryPlayerSettingsStore(),
        createPlayer: () async {
          final driver = _CoreDriver();
          drivers.add(driver);
          return driver;
        },
      );
      addTearDown(backend.dispose);
      Future<void> open(bool changed) => backend.open(
        VideoOpenRequest(
          sessionId: changed ? 2 : 1,
          url: Uri.parse('http://127.0.0.1:9/video'),
          cacheIdentity: changed && change == 'source' ? 'other' : 'same',
          credentialHeaders: {
            'Token': changed && change == 'credentials' ? 'new' : 'old',
          },
          isInfiniteStream: changed && change == 'dynamic',
        ),
      );
      await open(false);
      final previousRoute = drivers.single.request!.url;
      await backend.suspend();
      if (change == 'stop') await backend.stop();
      await open(true);
      expect(drivers.last.request!.url, isNot(previousRoute));
      await backend.suspend();
      await backend.dispose();
      expect((await backend.diagnostics())['transportAttached'], isFalse);
    });
  }

  cases.test(
    'stop releases the previous transport before the next open',
    () async {
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
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: temp,
        createPlayer: () async => drivers[created++],
      );
      addTearDown(() async {
        await backend.dispose();
        await upstream.close(force: true);
        await deleteTemporaryDirectory(temp);
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
        ranges: const [
          BufferedRange(Duration(seconds: 1), Duration(seconds: 2)),
        ],
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
    },
  );

  cases.test(
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
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
        settingsStore: MemoryPlayerSettingsStore(
          const PlayerSettings(hardwareDecoding: HardwareDecodingMode.off),
        ),
        diskCacheDirectory: temp,
        createPlayer: () async => driver,
      );
      addTearDown(() async {
        await backend.dispose();
        await upstream.close(force: true);
        await deleteTemporaryDirectory(temp);
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

  cases.test(
    'upstream 401 reports authentication required after failed open',
    () async {
      final temp = await Directory.systemTemp.createTemp('rillight-core-auth-');
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
      });
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: temp,
        createPlayer: () async => _UnauthorizedCoreDriver(),
      );
      addTearDown(() async {
        await backend.dispose();
        await upstream.close(force: true);
        await deleteTemporaryDirectory(temp);
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

  cases.test(
    'transcode marks only external subtitle tracks as external',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'rillight-core-tracks-',
      );
      final driver = _CoreDriver();
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: temp,
        createPlayer: () async => driver,
      );
      addTearDown(() async {
        await backend.dispose();
        await deleteTemporaryDirectory(temp);
      });
      await backend.open(
        VideoOpenRequest(
          sessionId: 4,
          url: Uri.parse('http://127.0.0.1:8765/stream.m3u8'),
          playMethod: PlayMethod.transcode,
          mediaStreams: const [
            MediaStreamInfo(index: 0, type: 'Video', videoRange: 'SDR'),
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
      expect(driver.request!.streams.first.toChannel()['videoRange'], 'SDR');
    },
  );

  cases.test(
    'confirmed external subtitle retains its server track index',
    () async {
      final temp = await Directory.systemTemp.createTemp('rillight-core-srt-');
      final subtitleRoot = await Directory.systemTemp.createTemp(
        'rillight-subtitles-',
      );
      final subtitle = File('${subtitleRoot.path}/selected.srt');
      await subtitle.writeAsString('1\n00:00:00,000 --> 00:00:01,000\nHello\n');
      final driver = _CoreDriver();
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: temp,
        createPlayer: () async => driver,
      );
      addTearDown(() async {
        await backend.dispose();
        await subtitleRoot.delete(recursive: true);
        await deleteTemporaryDirectory(temp);
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
    },
  );

  cases.test(
    'later core output samples replace kind and tier without moving playback',
    () async {
      final driver = _CoreDriver();
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
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
        'decodeDiagnostics': 'd3d11 threads=4',
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
      expect(backend.outputStatus.decodePath, 'd3d11 threads=4');
      expect(backend.outputStatus.outputColorSpace, 'scRGB');
      expect(backend.outputStatus.hdrDisplayActive, isTrue);
      driver.emit('outputStatus', {
        'dolbyVisionProfile': 5,
        'decodeDiagnostics': 'software threads=4',
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
      expect(backend.outputStatus.decodePath, 'software threads=4');
      expect(
        (await backend.diagnostics())['coreDecodeDiagnostics'],
        'software threads=4',
      );
      expect(backend.outputStatus.audioDelivery, 2);
      expect(backend.outputStatus.effectiveInterpolation, 0);
      expect(backend.outputStatus.reasonInterpolation, 4);
      expect(backend.outputStatus.outputColorSpace, 'scRGB');
      expect(backend.outputStatus.hdrDisplayActive, isTrue);
      expect(backend.position, position);
      expect(backend.isPlaying, isFalse);
    },
  );
  cases.test(
    'stale output refresh cannot overwrite a newer frame sample',
    () async {
      final driver = _StaleOutputCoreDriver();
      final backend = RillightVideoBackend(
        mediaHeaderTimeout: const Duration(milliseconds: 800),
        sourceStallTimeout: const Duration(milliseconds: 150),
        waitForRetry: _retryImmediately,
        settingsStore: MemoryPlayerSettingsStore(),
        diskCacheDirectory: isolatedCache,
        createPlayer: () async => driver,
      );
      addTearDown(backend.dispose);
      await backend.open(
        VideoOpenRequest(
          sessionId: 44,
          url: Uri.parse('http://127.0.0.1:1/output.mp4'),
        ),
      );
      await backend.refreshOutputStatus();
      expect(backend.outputStatus.videoOutputKind, 1);
      expect(backend.outputStatus.audioDelivery, 3);
      expect(driver.commands, isNot(contains('enhancement')));
    },
  );
}

Future<void> _retryImmediately(Duration delay) =>
    Future<void>.delayed(Duration.zero);

final cases = CaseShard(3);

void mainShard(int part, int expectedParts) =>
    cases.register(part, main, expectedParts: expectedParts);
