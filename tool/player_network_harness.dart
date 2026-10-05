// Exercises the real playback proxy/cache against an isolated synthetic origin.
// Application-level delays/disconnects model weak links, not TCP packet loss or
// native video/audio performance. Run baseline and candidate on the same host.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:rillight/player/cache/http_cache_policy.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';
import 'package:rillight/player/playback_http_proxy.dart';

const _mib = 1024 * 1024;
int _total = 24 * _mib;
const _profiles = {
  'untagged': (latencyMs: 250, chunkMs: 0, stallMs: 0, disconnectBytes: 0),
  'untagged-single-stream-403': (
    latencyMs: 250,
    chunkMs: 2,
    stallMs: 0,
    disconnectBytes: 0,
  ),
  'untagged-netem-loss': (
    latencyMs: 0,
    chunkMs: 0,
    stallMs: 0,
    disconnectBytes: 0,
  ),
  'hls-latency': (latencyMs: 180, chunkMs: 5, stallMs: 0, disconnectBytes: 0),
  'hls-single-stream-403': (
    latencyMs: 180,
    chunkMs: 5,
    stallMs: 0,
    disconnectBytes: 0,
  ),
  'hls-netem-loss': (latencyMs: 0, chunkMs: 0, stallMs: 0, disconnectBytes: 0),
  'fast': (latencyMs: 0, chunkMs: 0, stallMs: 0, disconnectBytes: 0),
  'startup-handoff': (
    latencyMs: 250,
    chunkMs: 0,
    stallMs: 0,
    disconnectBytes: 0,
  ),
  'startup-cold': (latencyMs: 250, chunkMs: 0, stallMs: 0, disconnectBytes: 0),
  'native-seek': (latencyMs: 250, chunkMs: 8, stallMs: 0, disconnectBytes: 0),
  'node-outage': (latencyMs: 250, chunkMs: 0, stallMs: 0, disconnectBytes: 0),
  'unhealthy-node': (
    latencyMs: 250,
    chunkMs: 0,
    stallMs: 0,
    disconnectBytes: 0,
  ),
  'latency': (latencyMs: 250, chunkMs: 12, stallMs: 0, disconnectBytes: 0),
  'shared-limit': (latencyMs: 250, chunkMs: 0, stallMs: 0, disconnectBytes: 0),
  'jitter': (latencyMs: 250, chunkMs: 8, stallMs: 150, disconnectBytes: 0),
  'disconnect': (latencyMs: 150, chunkMs: 4, stallMs: 0, disconnectBytes: _mib),
  'single-stream-403': (
    latencyMs: 150,
    chunkMs: 4,
    stallMs: 0,
    disconnectBytes: 0,
  ),
  'netem-latency': (latencyMs: 0, chunkMs: 0, stallMs: 0, disconnectBytes: 0),
  'netem-loss': (latencyMs: 0, chunkMs: 0, stallMs: 0, disconnectBytes: 0),
  'netem-loss-high': (latencyMs: 0, chunkMs: 0, stallMs: 0, disconnectBytes: 0),
};

Future<void> main(List<String> args) async {
  String option(String name, String fallback) {
    final index = args.indexOf(name);
    return index < 0 ? fallback : args[index + 1];
  }

  final label = option('--label', 'candidate');
  final trials = int.parse(option('--trials', '3'));
  final selected = option('--scenario', 'all');
  _total = int.parse(option('--size-mib', '24')) * _mib;
  if (_total < 4 * _mib) throw ArgumentError('Use at least 4 MiB');
  if (trials < 1 || selected != 'all' && !_profiles.containsKey(selected)) {
    throw ArgumentError('Invalid trials/scenario');
  }
  final output = Directory(
    'build/player-validation/network-$label-${DateTime.now().millisecondsSinceEpoch}',
  );
  await output.create(recursive: true);
  final sourceHashes = <String, String>{};
  for (final source in [
    'player/playback_http_proxy.dart',
    'player/cache/session_read_ahead.dart',
    'player/cache/response_read_ahead.dart',
  ]) {
    final uri = await Isolate.resolvePackageUri(
      Uri.parse('package:rillight/$source'),
    );
    if (uri == null || !await File.fromUri(uri).exists()) continue;
    final digest = await Sha256().hash(await File.fromUri(uri).readAsBytes());
    sourceHashes[source] = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }
  final rows = <Map<String, Object?>>[];
  var failed = false;
  for (final profile in _profiles.keys.where(
    (key) => selected == 'all' ? !key.contains('netem-') : selected == key,
  )) {
    for (var trial = 0; trial < trials; trial++) {
      for (final seek in [false, true]) {
        final row = await _run(profile, seek);
        row.addAll({'label': label, 'trial': trial});
        rows.add(row);
        failed |= row['success'] != true;
        stdout.writeln(jsonEncode(row));
        await File(
          '${output.path}/raw.jsonl',
        ).writeAsString('${jsonEncode(row)}\n', mode: FileMode.append);
      }
    }
  }
  await File('${output.path}/report.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'dart': Platform.version,
      'os': Platform.operatingSystemVersion,
      'sourceHashes': sourceHashes,
      'mediaBytes': _total,
      'evidence':
          'HTTP byte delivery; netem profiles inject Linux TCP packet loss. Not native playback acceptance.',
      'profiles': {
        for (final entry in _profiles.entries)
          entry.key: entry.value.toString(),
      },
      'rows': rows,
    }),
  );
  stdout.writeln('Evidence: ${output.absolute.path}');
  if (failed) exitCode = 1;
}

Future<Map<String, Object?>> _run(String profile, bool seek) async {
  if (profile.startsWith('hls-')) return _runHls(profile, seek);
  final config = _profiles[profile]!;
  final root = await Directory.systemTemp.createTemp('rillight-network-');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final netem = profile.contains('netem-');
  if (netem) {
    await _configureNetem(
      profile.substring(profile.indexOf('netem-')),
      server.port,
    );
  }
  final client = HttpClient();
  final cache = await SessionByteCache.open(
    root: root,
    memoryLimitBytes: 8 * _mib,
    diskLimitBytes: 64 * _mib,
  );
  final proxy = await PlaybackHttpProxy.create(
    cache: cache,
    sessionBuffering: true,
    readAheadBytes: 32 * _mib,
  );
  var requests = 0;
  var active = 0;
  var peak = 0;
  var upstreamBytes = 0;
  var refusals = 0;
  var streaming = 0;
  final connections = <int, int>{};
  var nextSharedChunk = DateTime.now();
  final delivered = <(int, int)>[];
  final handlers = <Future<void>>{};
  Future<void> serve(HttpRequest request) async {
    requests++;
    active++;
    peak = max(peak, active);
    var ownsStream = false;
    try {
      await Future<void>.delayed(Duration(milliseconds: config.latencyMs));
      if (profile == 'node-outage' && requests >= 2 && requests <= 7) {
        request.response.statusCode = HttpStatus.badGateway;
        request.response.write('backend temporarily unavailable');
        await request.response.close();
        return;
      }
      if (profile == 'unhealthy-node') {
        final node = connections.putIfAbsent(
          request.connectionInfo!.remotePort,
          () => connections.length % 2,
        );
        if (node == 0) {
          request.response.statusCode = HttpStatus.badGateway;
          request.response.write('backend unavailable');
          await request.response.close();
          return;
        }
      }
      if (profile.endsWith('single-stream-403') && streaming > 0) {
        refusals++;
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      streaming++;
      ownsStream = true;
      final range = MediaByteRange.resolve(
        request.headers.value('range'),
        _total,
      )!;
      final output = request.response;
      output.statusCode = 206;
      if (!profile.startsWith('untagged')) {
        output.headers.set('etag', '"synthetic-v1"');
      }
      output.headers.set(
        'content-range',
        'bytes ${range.start}-${range.end}/$_total',
      );
      output.contentLength = range.length;
      final socket = await output.detachSocket(writeHeaders: true);
      var disconnected = false;
      final input = socket.listen(
        (_) {},
        onDone: () => disconnected = true,
        onError: (Object _) => disconnected = true,
      );
      try {
        var sent = 0;
        while (sent < range.length) {
          var delay = config.chunkMs;
          if (sent > 0 && sent % (_mib ~/ 2) == 0) delay += config.stallMs;
          if (delay > 0) {
            await Future<void>.delayed(Duration(milliseconds: delay));
          }
          if (profile == 'shared-limit') {
            final now = DateTime.now();
            if (nextSharedChunk.isBefore(now)) nextSharedChunk = now;
            final slot = nextSharedChunk;
            nextSharedChunk = slot.add(const Duration(milliseconds: 12));
            await Future<void>.delayed(slot.difference(now));
          }
          if (disconnected) return;
          final length = min(64 * 1024, range.length - sent);
          final start = range.start + sent;
          socket.add(
            Uint8List.fromList(List.generate(length, (i) => (start + i) % 251)),
          );
          await socket.flush();
          upstreamBytes += length;
          delivered.add((start, start + length));
          sent += length;
          if (config.disconnectBytes > 0 && sent >= config.disconnectBytes) {
            break;
          }
        }
      } finally {
        socket.destroy();
        await input.cancel();
      }
    } catch (_) {
      // A seek/close intentionally cancels synthetic requests.
    } finally {
      active--;
      if (ownsStream) streaming--;
    }
  }

  server.listen((request) {
    late final Future<void> task;
    task = serve(request).whenComplete(() => handlers.remove(task));
    handlers.add(task);
  });
  final route = proxy.register(
    Uri.parse('http://127.0.0.1:${server.port}/media'),
  );
  final watch = Stopwatch();
  var firstByteMs = -1;
  var received = 0;
  var lastDeliveryMs = 0;
  var maxDeliveryGapMs = 0;
  var deliveryStalls = 0;
  var rssPeak = ProcessInfo.currentRss;
  int? downloadedDuringDecoderPause;
  final sampling = Timer.periodic(const Duration(milliseconds: 25), (_) {
    rssPeak = max(rssPeak, ProcessInfo.currentRss);
  });
  final start = seek ? _total * 2 ~/ 3 : 0;
  String? error;
  String? networkStats;
  try {
    if (profile.startsWith('startup-')) {
      proxy.setPlaybackActive(false);
      if (profile == 'startup-handoff') {
        final probe = await client.getUrl(route);
        probe.headers.set('range', 'bytes=0-8191');
        await (await probe.close()).drain<void>();
      }
    }
    if (seek) {
      final request = await client.getUrl(route);
      request.headers.set('range', 'bytes=0-${_total - 1}');
      final response = await request.close();
      await response.first;
      // Native desktop seek closes its own old HTTP response atomically with
      // the decoder timeline; it deliberately does not call transport.seek().
      if (profile != 'native-seek') proxy.cancelPendingReads();
    }
    watch.start();
    await (() async {
      while (received < _total - start) {
        final request = await client.getUrl(route);
        request.headers.set('range', 'bytes=${start + received}-${_total - 1}');
        final response = await request.close();
        if (profile.startsWith('startup-')) proxy.setPlaybackActive(true);
        if (response.statusCode != 206) {
          throw StateError('Status ${response.statusCode}');
        }
        await for (final bytes in response) {
          final now = watch.elapsedMilliseconds;
          if (firstByteMs < 0) {
            firstByteMs = now;
          } else {
            final gap = now - lastDeliveryMs;
            maxDeliveryGapMs = max(maxDeliveryGapMs, gap);
            if (gap >= 500) deliveryStalls++;
          }
          lastDeliveryMs = now;
          for (var i = 0; i < bytes.length; i++) {
            if (bytes[i] != (start + received + i) % 251) {
              throw StateError('Corrupt byte at ${start + received + i}');
            }
          }
          received += bytes.length;
          if (profile == 'untagged' && downloadedDuringDecoderPause == null) {
            // Explicitly model the decoder presenting already decoded frames.
            // Measure source progress while the downstream body is paused.
            final before = proxy.upstreamBytes;
            await Future<void>.delayed(const Duration(seconds: 1));
            downloadedDuringDecoderPause = proxy.upstreamBytes - before;
            lastDeliveryMs = watch.elapsedMilliseconds;
          }
        }
      }
      if (received != _total - start) throw StateError('Incomplete response');
      if ((cache.diagnostics['memoryPeakBytes'] as int) > 8 * _mib ||
          (cache.diagnostics['pendingPeakBytes'] as int) >
              cache.pendingLimitBytes ||
          (proxy.diagnostics['proxyInFlightPeakBytes'] as int) > 12 * _mib) {
        throw StateError('Download exceeded workspace/cache budgets');
      }
      if (proxy.diagnostics['authenticationStatus'] != null) {
        throw StateError('Parallel refusal incorrectly expired authentication');
      }
    })().timeout(const Duration(seconds: 90));
  } catch (failure) {
    error = failure.toString();
  } finally {
    watch.stop();
    sampling.cancel();
    client.close(force: true);
    await proxy.close();
    await server.close(force: true);
    await Future.wait(handlers.toList());
    if (netem) {
      networkStats =
          (await Process.run('tc', [
                '-s',
                '-j',
                'qdisc',
                'show',
                'dev',
                'lo',
              ])).stdout
              as String;
      await _tc(['qdisc', 'del', 'dev', 'lo', 'root']);
    }
  }
  delivered.sort((a, b) => a.$1.compareTo(b.$1));
  var uniqueBytes = 0;
  var end = 0;
  for (final interval in delivered) {
    uniqueBytes += max(0, interval.$2 - max(end, interval.$1));
    end = max(end, interval.$2);
  }
  final result = <String, Object?>{
    'profile': profile,
    'netemStats': networkStats == null ? null : jsonDecode(networkStats),
    'seek': seek,
    'success': error == null,
    'error': error,
    'firstByteMs': firstByteMs,
    'downloadedDuringDecoderPause': downloadedDuringDecoderPause,
    'maxDeliveryGapMs': maxDeliveryGapMs,
    'deliveryStallsOver500Ms': deliveryStalls,
    'elapsedMs': watch.elapsedMilliseconds,
    'mibPerSecond': received / _mib / (watch.elapsedMicroseconds / 1e6),
    'receivedBytes': received,
    'upstreamBytes': upstreamBytes,
    'repeatedBytes': upstreamBytes - uniqueBytes,
    'requests': requests,
    'parallelRefusals': refusals,
    'peakConnections': peak,
    'rssPeakBytes': rssPeak,
    'transport': proxy.diagnostics,
    'cache': cache.diagnostics,
  };
  await root.delete(recursive: true);
  return result;
}

// A decoder consumes a burst of demux data, then presents it for one second.
// Account separately for that intentional pause and time waiting for HTTP data.
Future<Map<String, Object?>> _runHls(String profile, bool seek) async {
  final config = _profiles[profile]!;
  const length = 256 * 1024;
  final root = await Directory.systemTemp.createTemp('rillight-hls-network-');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final netem = profile == 'hls-netem-loss';
  if (netem) await _configureNetem('netem-loss', server.port);
  final cache = await SessionByteCache.open(
    root: root,
    memoryLimitBytes: 2 * _mib,
    diskLimitBytes: 32 * _mib,
  );
  final proxy = await PlaybackHttpProxy.create(
    cache: cache,
    sessionBuffering: true,
    readAheadBytes: 4 * _mib,
  );
  final client = HttpClient();
  var active = 0;
  var peak = 0;
  var requests = 0;
  var refusals = 0;
  var originBytes = 0;
  final counts = <int, int>{};
  final handlers = <Future<void>>{};
  final stopping = Completer<void>();
  Future<void> serve(HttpRequest request) async {
    var ownsStream = false;
    try {
      requests++;
      if (request.uri.path.endsWith('.m3u8')) {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.write(
          '#EXTM3U\n${List.generate(10, (i) => '#EXTINF:2,\n$i.ts\n').join()}#EXT-X-ENDLIST\n',
        );
      } else {
        if (profile == 'hls-single-stream-403' && active > 0) {
          refusals++;
          request.response.statusCode = 403;
          request.response.write('origin capacity reached');
          await request.response.close();
          return;
        }
        active++;
        ownsStream = true;
        peak = max(peak, active);
        final index = int.parse(request.uri.pathSegments.last.split('.').first);
        counts[index] = (counts[index] ?? 0) + 1;
        await Future<void>.delayed(Duration(milliseconds: config.latencyMs));
        final range = MediaByteRange.resolve(
          request.headers.value('range'),
          length,
        )!;
        request.response.headers.set('etag', '"segment-$index"');
        request.response.headers.set('cache-control', 'max-age=120');
        request.response.contentLength = range.length;
        if (request.headers.value('range') != null) {
          request.response.statusCode = 206;
          request.response.headers.set(
            'content-range',
            'bytes ${range.start}-${range.end}/$length',
          );
        }
        for (var offset = range.start; offset <= range.end;) {
          final size = min(16 * 1024, range.end - offset + 1);
          request.response.add(List<int>.filled(size, index + 1));
          originBytes += size;
          offset += size;
          await Future.any([request.response.flush(), stopping.future]);
          if (stopping.isCompleted) return;
          if (config.chunkMs > 0) {
            await Future<void>.delayed(Duration(milliseconds: config.chunkMs));
          }
        }
      }
      await Future.any([request.response.close(), stopping.future]);
    } catch (_) {
      // Seek/close deliberately retire in-flight synthetic responses.
    } finally {
      if (ownsStream) active--;
    }
  }

  server.listen((request) {
    late Future<void> task;
    task = serve(request).whenComplete(() => handlers.remove(task));
    handlers.add(task);
  });
  final watch = Stopwatch()..start();
  var received = 0;
  var waitingUs = 0;
  var initialMs = -1;
  var burstMs = -1;
  String? error;
  final waits = <int>[];
  try {
    final manifest = await (await client.getUrl(
      proxy.register(Uri.parse('http://127.0.0.1:${server.port}/index.m3u8')),
    )).close();
    final text = await manifest.transform(utf8.decoder).join();
    final urls = text
        .split('\n')
        .where((s) => s.startsWith('http://'))
        .map(Uri.parse)
        .toList();
    Future<void> read(int index) async {
      final readWatch = Stopwatch()..start();
      final response = await (await client.getUrl(urls[index])).close();
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw StateError('segment HTTP ${response.statusCode}');
      }
      var bytes = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (initialMs < 0) initialMs = watch.elapsedMilliseconds;
        if (chunk.any((b) => b != index + 1)) {
          throw StateError('wrong segment bytes');
        }
        bytes += chunk.length;
      }
      if (bytes != length) throw StateError('truncated segment');
      received += bytes;
      waitingUs += readWatch.elapsedMicroseconds;
      waits.add(readWatch.elapsedMilliseconds);
    }

    await read(0).timeout(const Duration(seconds: 35));
    // Model playback presentation time, not a wait for a test condition.
    await Future<void>.delayed(const Duration(seconds: 1));
    if (seek) proxy.cancelPendingReads();
    final burst = Stopwatch()..start();
    for (final index in seek ? [6, 7, 8, 9] : [1, 2, 3, 4]) {
      await read(index).timeout(const Duration(seconds: 35));
    }
    burstMs = burst.elapsedMilliseconds;
    if (cache.diagnostics['memoryPeakBytes'] as int > 2 * _mib ||
        cache.diagnostics['diskPeakBytes'] as int > 32 * _mib) {
      throw StateError('cache budget exceeded');
    }
  } catch (failure) {
    error = failure.runtimeType.toString();
  } finally {
    watch.stop();
    client.close(force: true);
    try {
      await proxy.close().timeout(const Duration(seconds: 10));
    } on TimeoutException {
      error ??= 'proxy close timeout';
    }
    stopping.complete();
    await server.close(force: true).timeout(const Duration(seconds: 10));
    try {
      await Future.wait(handlers.toList()).timeout(const Duration(seconds: 10));
    } on TimeoutException {
      error ??= 'origin handler close timeout';
    }
  }
  final row = <String, Object?>{
    'profile': profile,
    'seek': seek,
    'success': error == null,
    'error': error,
    'firstByteMs': initialMs,
    'elapsedMs': watch.elapsedMilliseconds,
    'mibPerSecond': received / _mib / (watch.elapsedMicroseconds / 1e6),
    'activeDeliveryMiBPerSecond': received / _mib / (waitingUs / 1e6),
    'burstWaitMs': burstMs,
    'segmentWaitMs': waits,
    'deliveryStallsOver500Ms': waits.where((ms) => ms > 500).length,
    'receivedBytes': received,
    'upstreamBytes': originBytes,
    'repeatedBytes': counts.values.fold<int>(
      0,
      (sum, n) => sum + max(0, n - 1) * length,
    ),
    'requests': requests,
    'parallelRefusals': refusals,
    'peakConnections': peak,
    'transport': proxy.diagnostics,
    'cache': cache.diagnostics,
    if (netem)
      'netem': (await Process.run('tc', [
        '-s',
        'qdisc',
        'show',
        'dev',
        'lo',
      ])).stdout,
  };
  await root.delete(recursive: true);
  return row;
}

Future<void> _tc(List<String> args) async {
  final result = await Process.run('tc', args);
  if (result.exitCode != 0) throw StateError('tc failed: ${result.stderr}');
}

Future<void> _configureNetem(String profile, int port) async {
  if (!Platform.isLinux) {
    throw StateError('Run netem profiles in the isolated Docker harness');
  }
  // Full-read and seek trials use new origin ports in the same disposable
  // container. Replacing the root alone retains its old children/filters.
  // Remove that trial's tree before installing the next isolated profile.
  await Process.run('tc', ['qdisc', 'del', 'dev', 'lo', 'root']);
  for (final command in [
    ['ip', 'link', 'set', 'lo', 'mtu', '1500'],
    ['ethtool', '-K', 'lo', 'tso', 'off', 'gso', 'off', 'gro', 'off'],
  ]) {
    final result = await Process.run(command.first, command.skip(1).toList());
    if (result.exitCode != 0) {
      throw StateError('Packet sizing failed: ${result.stderr}');
    }
  }
  await _tc([
    'qdisc',
    'replace',
    'dev',
    'lo',
    'root',
    'handle',
    '1:',
    'prio',
    'bands',
    '3',
    'priomap',
    ...List.filled(16, '2'),
  ]);
  final severe = profile == 'netem-loss-high';
  await _tc([
    'qdisc',
    'add',
    'dev',
    'lo',
    'parent',
    '1:1',
    'handle',
    '10:',
    'netem',
    'limit',
    '10000',
    'delay',
    severe ? '300ms' : '200ms',
    severe ? '50ms' : '20ms',
    'loss',
    profile == 'netem-latency'
        ? '0%'
        : severe
        ? '3%'
        : '1%',
    'rate',
    severe ? '20mbit' : '30mbit',
  ]);
  // Only synthetic-origin response packets. The player's loopback response,
  // control traffic and all traffic outside this container remain untouched.
  await _tc([
    'filter',
    'add',
    'dev',
    'lo',
    'protocol',
    'ip',
    'parent',
    '1:',
    'prio',
    '1',
    'u32',
    'match',
    'ip',
    'sport',
    '$port',
    '0xffff',
    'flowid',
    '1:1',
  ]);
}
