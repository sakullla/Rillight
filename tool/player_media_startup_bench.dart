// Windows native decoded-frame timing through the production proxy/cache.
// Use synthetic media only. Does not measure Flutter pixels or physical audio.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:rillight/player/cache/http_cache_policy.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';
import 'package:rillight/player/playback_http_proxy.dart';

Future<void> main(List<String> args) async {
  String option(String key, String fallback) {
    final index = args.indexOf(key);
    return index < 0 ? fallback : args[index + 1];
  }

  final media = await File(option('--media', '')).readAsBytes();
  final delay = int.parse(option('--latency-ms', '250'));
  final trials = int.parse(option('--trials', '3'));
  final coreDirectory = option(
    '--core-directory',
    'build/windows/x64/runner/Release',
  );
  final hashes = <String, String>{};
  for (final path in [
    'lib/player/playback_http_proxy.dart',
    'lib/player/cache/session_read_ahead.dart',
    '$coreDirectory/librillight_core.dll',
    option('--media', ''),
  ]) {
    hashes[path] = (await Sha256().hash(
      await File(path).readAsBytes(),
    )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
  for (var trial = 0; trial < trials; trial++) {
    final root = await Directory.systemTemp.createTemp('rillight-startup-');
    final cache = await SessionByteCache.open(
      root: root,
      memoryLimitBytes: 8 * 1024 * 1024,
      diskLimitBytes: 256 * 1024 * 1024,
    );
    final proxy = await PlaybackHttpProxy.create(
      cache: cache,
      sessionBuffering: true,
      readAheadBytes: 128 * 1024 * 1024,
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final watch = Stopwatch()..start();
    final requests = <Map<String, int>>[];
    final handlers = <Future<void>>{};
    var stopped = false;
    Future<void> serve(HttpRequest request) async {
      final range = MediaByteRange.resolve(
        request.headers.value('range'),
        media.length,
      )!;
      requests.add({
        'atMs': watch.elapsedMilliseconds,
        'start': range.start,
        'end': range.end,
      });
      try {
        await Future<void>.delayed(Duration(milliseconds: delay));
        final output = request.response;
        output.statusCode = 206;
        output.headers.set('etag', '"synthetic-startup"');
        output.headers.set(
          'content-range',
          'bytes ${range.start}-${range.end}/${media.length}',
        );
        output.contentLength = range.length;
        for (var at = range.start; at <= range.end && !stopped; at += 65536) {
          output.add(media.sublist(at, min(at + 65536, range.end + 1)));
          await output.flush();
          await Future<void>.delayed(const Duration(milliseconds: 4));
        }
        await output.close();
      } on IOException {
        // Demuxer probes and seeks intentionally cancel old responses.
      }
    }

    server.listen((request) {
      late final Future<void> task;
      task = serve(request).whenComplete(() => handlers.remove(task));
      handlers.add(task);
    });
    try {
      final route = proxy.register(
        Uri.parse('http://127.0.0.1:${server.port}/fixture.mkv'),
      );
      final result = await Process.run('python', [
        'tool/player_media_startup_probe.py',
        '--core-directory',
        coreDirectory,
        '--resume-ms',
        option('--resume-ms', '12000'),
        '--url',
        route.toString(),
      ]);
      if (result.exitCode != 0) {
        throw StateError('Synthetic probe failed: ${result.stderr}');
      }
      stdout.writeln(
        jsonEncode({
          'trial': trial,
          'latencyMs': delay,
          'dart': Platform.version,
          'sourceHashes': hashes,
          ...jsonDecode(result.stdout as String) as Map<String, dynamic>,
          'requests': requests,
          'upstreamBytes': proxy.upstreamBytes,
        }),
      );
    } finally {
      stopped = true;
      await proxy.close();
      await server.close(force: true);
      await Future.wait(handlers);
      await root.delete(recursive: true);
    }
  }
}
