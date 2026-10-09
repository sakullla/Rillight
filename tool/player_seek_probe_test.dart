// Explicit Windows native probe; excluded from the ordinary test/ suite.
// Use a verified core/SDK and synthetic media only. See global_optimization.md.
// Frames are drained into a headless sink: this does not validate a window,
// physical audio, presentation timing, or hardware performance.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/rillight_video_backend.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight_player/rillight_player.dart';

// Only the stable prefix of RillightCoreFrame is read; ownership stays native.
final class _FrameReceipt extends Struct {
  @Uint32()
  external int structSize;
  @Int32()
  external int type;
  @Uint64()
  external int session;
  @Uint64()
  external int timeline;
  @Int64()
  external int ptsUs;
}

class _RealHttp extends HttpOverrides {}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(
    ready(),
    isTrue,
    reason: 'New timeline did not produce advancing video',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native next episode and seek with warmed prefixes', () async {
    if (!Platform.isWindows) throw UnsupportedError('Windows probe only');
    final corePath = Platform.environment['RILLIGHT_SEEK_CORE'];
    final mediaPath = Platform.environment['RILLIGHT_SEEK_MEDIA'];
    if (corePath == null || mediaPath == null) {
      throw StateError('Set RILLIGHT_SEEK_CORE and RILLIGHT_SEEK_MEDIA');
    }
    final targetSeconds = int.parse(
      Platform.environment['RILLIGHT_SEEK_TARGET_SECONDS'] ?? '20',
    );
    final delayMs = int.parse(
      Platform.environment['RILLIGHT_SEEK_CHUNK_DELAY_MS'] ?? '2',
    );
    expect(targetSeconds, greaterThan(0));
    expect(delayMs, inInclusiveRange(0, 1000));
    // Flutter tests default to Android even on Windows hosts. That would ask
    // the core for an absent MediaCodec Surface and invalidate this probe.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await HttpOverrides.runWithHttpOverrides(() async {
      final libraryPath = File(corePath).absolute.path;
      final library = DynamicLibrary.open(libraryPath);
      final take = library
          .lookupFunction<
            Pointer<_FrameReceipt> Function(Pointer<Void>, Int32),
            Pointer<_FrameReceipt> Function(Pointer<Void>, int)
          >('rillight_core_take_frame');
      final release = library
          .lookupFunction<
            Void Function(Pointer<_FrameReceipt>),
            void Function(Pointer<_FrameReceipt>)
          >('rillight_core_release_frame');
      final timers = <int, Timer>{};
      final receipts = <int, ({int count, int timeline, int ptsUs})>{};
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('rillight_player');
      messenger.setMockMethodCallHandler(channel, (call) async {
        final address = (call.arguments as Map?)?['handle'] as int?;
        if (call.method == 'create') {
          final handle = address!;
          receipts[handle] = (count: 0, timeline: 0, ptsUs: -1);
          timers[handle] = Timer.periodic(const Duration(milliseconds: 10), (
            _,
          ) {
            for (final type in [1, 2]) {
              for (var i = 0; i < 5; i++) {
                final frame = take(Pointer<Void>.fromAddress(handle), type);
                if (frame == nullptr) break;
                try {
                  if (type == 1) {
                    receipts[handle] = (
                      count: receipts[handle]!.count + 1,
                      timeline: frame.ref.timeline,
                      ptsUs: frame.ref.ptsUs,
                    );
                  }
                } finally {
                  release(frame);
                }
              }
            }
          });
          return 1;
        }
        if (call.method == 'status') {
          final receipt = receipts[address];
          return {'frames': receipt?.count ?? 0, 'timeline': receipt?.timeline};
        }
        if (call.method == 'dispose') {
          timers.remove(address)?.cancel();
          receipts.remove(address);
        }
        return null;
      });
      addTearDown(() {
        for (final timer in timers.values) {
          timer.cancel();
        }
        messenger.setMockMethodCallHandler(channel, null);
      });
      final bytes = await File(mediaPath).readAsBytes();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var closing = false;
      final requests = <Future<void>>{};
      Future<void> serve(HttpRequest request) async {
        try {
          final range = RegExp(
            r'^bytes=(\d+)-(\d*)$',
          ).firstMatch(request.headers.value('range') ?? 'bytes=0-');
          if (range == null || int.parse(range[1]!) >= bytes.length) {
            request.response.statusCode =
                HttpStatus.requestedRangeNotSatisfiable;
            await request.response.close();
            return;
          }
          final start = int.parse(range[1]!);
          final end = math.min(
            range[2]!.isEmpty ? bytes.length - 1 : int.parse(range[2]!),
            bytes.length - 1,
          );
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            'content-range',
            'bytes $start-$end/${bytes.length}',
          );
          request.response.headers.set('etag', '"${request.uri.path}"');
          request.response.contentLength = end - start + 1;
          for (var offset = start; !closing && offset <= end; offset += 65536) {
            request.response.add(
              Uint8List.sublistView(
                bytes,
                offset,
                math.min(offset + 65536, end + 1),
              ),
            );
            await request.response.flush();
            await Future<void>.delayed(Duration(milliseconds: delayMs));
          }
          await request.response.close();
        } on IOException {
          // Native seeks intentionally close the old downstream response.
        }
      }

      server.listen((request) {
        final work = serve(request);
        requests.add(work);
        unawaited(work.whenComplete(() => requests.remove(work)));
      });
      final cacheRoot = await Directory(
        'build/player-seek-probe',
      ).create(recursive: true);
      final cache = await cacheRoot.createTemp('cache-');
      final backend = RillightVideoBackend(
        diskCacheDirectory: cache,
        settingsStore: MemoryPlayerSettingsStore(),
        createPlayer: () => CorePlayer.create(libraryPath: libraryPath),
      );
      try {
        for (var episode = 1; episode <= 3; episode++) {
          await backend.open(
            VideoOpenRequest(
              sessionId: episode,
              url: Uri.parse(
                'http://127.0.0.1:${server.port}/episode-$episode',
              ),
              warmedPrefix: episode == 1
                  ? null
                  : Uint8List.sublistView(
                      bytes,
                      0,
                      math.min(bytes.length, 1024 * 1024),
                    ),
            ),
          );
          await _until(
            () =>
                receipts.values.single.count >= 3 &&
                receipts.values.single.ptsUs > 0,
          );
          expect(backend.duration.inSeconds, greaterThan(targetSeconds + 1));
          final before = receipts.values.single;
          stdout.writeln(
            jsonEncode({
              'phase': 'beforeSeek',
              'episode': episode,
              'frames': before.count,
              'ptsUs': before.ptsUs,
            }),
          );
          final watch = Stopwatch()..start();
          await backend
              .seek(Duration(seconds: targetSeconds))
              .timeout(const Duration(seconds: 15));
          await _until(() {
            final current = receipts.values.single;
            return current.timeline > before.timeline &&
                current.count > before.count + 2 &&
                current.ptsUs > targetSeconds * 1000000 + 100000;
          });
          final after = receipts.values.single;
          final diagnostics = await backend.diagnostics();
          stdout.writeln(
            jsonEncode({
              'episode': episode,
              'warmPrefix': episode > 1,
              'targetSeconds': targetSeconds,
              'chunkDelayMs': delayMs,
              'seekAndFramesMs': watch.elapsedMilliseconds,
              'timelineBefore': before.timeline,
              'timelineAfter': after.timeline,
              'framePtsUs': after.ptsUs,
              'decoder': diagnostics['coreActualHardwareName'],
            }),
          );
        }
      } catch (_) {
        stdout.writeln(jsonEncode(await backend.diagnostics()));
        rethrow;
      } finally {
        try {
          await backend.dispose();
        } finally {
          closing = true;
          await server.close(force: true);
          await Future.wait(requests.toList());
          await cache.delete(recursive: true);
        }
      }
    }, _RealHttp());
  }, timeout: const Timeout(Duration(minutes: 3)));
}
