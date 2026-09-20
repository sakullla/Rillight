// Synthetic HTTP transport benchmark. Times are byte delivery, NOT first-frame
// or video seek latency; native rendering is measured by player_smoke instead.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:rillight/player/cache/session_byte_cache.dart';
import 'package:rillight/player/playback_http_proxy.dart';

const _mib = 1024 * 1024;

Future<void> main(List<String> args) async {
  final output = Directory(
    'build/player-validation/cache-benchmark-${DateTime.now().millisecondsSinceEpoch}',
  );
  await output.create(recursive: true);
  if (args.contains('--protection-only')) {
    for (var trial = 0; trial < 5; trial++) {
      final result = await _largeProtection();
      stdout.writeln(jsonEncode(result));
      await File(
        '${output.path}/large-protection-$trial.json',
      ).writeAsString(jsonEncode(result));
    }
    stdout.writeln('Evidence: ${output.absolute.path}');
    return;
  }
  final rows = <Map<String, Object?>>[];
  for (final scenario in [
    'stable',
    'limited',
    'outage',
    'overquota',
    'limited-overquota',
    'disk-fault',
  ]) {
    for (var trial = 0; trial < 5; trial++) {
      // Alternate order so baseline does not systematically receive cold JIT.
      for (final enabled in trial.isEven ? [false, true] : [true, false]) {
        final row = await _run(scenario, trial, enabled);
        rows.add(row);
        await File(
          '${output.path}/raw.jsonl',
        ).writeAsString('${jsonEncode(row)}\n', mode: FileMode.append);
        stdout.writeln(jsonEncode(row));
      }
    }
  }
  final summary = <Map<String, Object?>>[];
  for (final scenario in rows.map((row) => row['scenario']).toSet()) {
    for (final enabled in [false, true]) {
      final subset = rows.where(
        (r) => r['scenario'] == scenario && r['cache'] == enabled,
      );
      final item = <String, Object?>{'scenario': scenario, 'cache': enabled};
      for (final key in [
        'firstByteMs',
        'initialReadMs',
        'repeatReadMs',
        'upstreamBytes',
        'rssPeakBytes',
      ]) {
        final values = subset.map((r) => r[key] as num).toList()..sort();
        item[key] = {
          'median': values[2],
          'min': values.first,
          'max': values.last,
        };
      }
      item['repeatSuccesses'] = subset
          .where((r) => r['repeatSucceeded'] == true)
          .length;
      summary.add(item);
    }
  }
  await File(
    '${output.path}/summary.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(summary));
  final protection = await _largeProtection();
  await File(
    '${output.path}/large-protection.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(protection));
  stdout.writeln(jsonEncode(protection));
  stdout.writeln('Evidence: ${output.absolute.path}');
}

Future<Map<String, Object?>> _largeProtection() async {
  final root = await Directory.systemTemp.createTemp(
    'rillight-large-protection-',
  );
  final cache = await SessionByteCache.open(
    root: root,
    memoryLimitBytes: 0,
    pendingLimitBytes: 4 * _mib,
    diskLimitBytes: 96 * _mib,
  );
  try {
    for (var offset = 0; offset < 64 * _mib; offset += _mib) {
      await cache.put(
        resource: 'large',
        generation: 1,
        offset: offset,
        bytes: Uint8List.fromList(List.filled(_mib, offset ~/ _mib)),
      );
    }
    final watch = Stopwatch()..start();
    final lease = await cache.protectRange(
      resource: 'large',
      generation: 1,
      offset: 0,
      length: 64 * _mib,
    );
    final protectMs = watch.elapsedMilliseconds;
    if (lease == null) {
      throw StateError('64 MiB range protection failed: ${cache.diagnostics}');
    }
    watch.reset();
    for (var offset = 0; offset < 64 * _mib; offset += _mib) {
      final read = await lease.read(offset, maxLength: _mib);
      if (read == null ||
          read.bytes.length != _mib ||
          read.bytes.any((value) => value != offset ~/ _mib)) {
        final files = root
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.block'))
            .toList();
        throw StateError(
          '64 MiB range unavailable at $offset; '
          'received=${read?.bytes.length}; diagnostics=${cache.diagnostics}; '
          'blocks=${files.length}; lengths=${files.map((file) => file.lengthSync()).toSet()}; '
          'firstValues=${files.map((file) {
            final handle = file.openSync();
            try {
              return handle.readByteSync();
            } finally {
              handle.closeSync();
            }
          }).toList()}',
        );
      }
    }
    final readMs = watch.elapsedMilliseconds;
    await lease.close();
    final stats = cache.diagnostics;
    if (stats['degradation'] != null) {
      throw StateError('Large cache degraded: $stats');
    }
    await cache.close();
    return {
      'bytes': 64 * _mib,
      'protectMs': protectMs,
      'readMs': readMs,
      'diskTimeoutMs': 750,
      'diagnostics': stats,
      'cleanup': cache.diagnostics['cleanup'],
    };
  } finally {
    await cache.close();
    await root.delete(recursive: true);
  }
}

Future<Map<String, Object?>> _run(
  String scenario,
  int trial,
  bool enabled,
) async {
  final root = await Directory.systemTemp.createTemp(
    'rillight-cache-benchmark-',
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final client = HttpClient();
  var offline = false;
  var upstreamBytes = 0;
  var upstreamRequests = 0;
  var rssPeak = ProcessInfo.currentRss;
  final sampling = Timer.periodic(const Duration(milliseconds: 10), (_) {
    rssPeak = max(rssPeak, ProcessInfo.currentRss);
  });
  const total = 8 * _mib;
  server.listen((request) async {
    upstreamRequests++;
    try {
      if (offline) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
      final range = RegExp(
        r'^bytes=(\d+)-(\d*)$',
      ).firstMatch(request.headers.value('range') ?? '');
      final start = range == null ? 0 : int.parse(range[1]!);
      final end = range == null || range[2]!.isEmpty
          ? total - 1
          : min(total - 1, int.parse(range[2]!));
      request.response.statusCode = range == null ? 200 : 206;
      request.response.headers.set('etag', '"synthetic-v1"');
      request.response.headers.set('cache-control', 'max-age=600');
      request.response.headers.set('accept-ranges', 'bytes');
      request.response.contentLength = end - start + 1;
      if (range != null) {
        request.response.headers.set(
          'content-range',
          'bytes $start-$end/$total',
        );
      }
      for (var offset = start; offset <= end; offset += 64 * 1024) {
        final length = min(64 * 1024, end - offset + 1);
        if (scenario.startsWith('limited')) {
          await Future<void>.delayed(const Duration(milliseconds: 12));
        }
        final bytes = Uint8List.fromList(
          List.generate(length, (i) => (offset + i) % 251),
        );
        request.response.add(bytes);
        upstreamBytes += length;
        await request.response.flush();
      }
      await request.response.close();
    } catch (_) {
      /* A cancelled consumer closes its synthetic upstream. */
    }
  });
  SessionByteCache? store;
  PlaybackHttpProxy? proxy;
  try {
    var diskRoot = Directory('${root.path}/cache');
    if (scenario == 'disk-fault') {
      await File('${root.path}/unwritable').writeAsString('not-a-directory');
      diskRoot = Directory('${root.path}/unwritable/cache');
    }
    if (enabled) {
      store = await SessionByteCache.open(
        root: diskRoot,
        memoryLimitBytes: 256 * 1024,
        pendingLimitBytes: 4 * _mib,
        diskLimitBytes: scenario.contains('overquota') ? 2 * _mib : 4 * _mib,
      );
    }
    proxy = await PlaybackHttpProxy.create(cache: store);
    final uri = proxy.register(
      Uri.parse('http://127.0.0.1:${server.port}/movie'),
    );
    var firstByteMs = 0;
    Future<int> fetch(int start, int length, {bool initial = false}) async {
      final watch = Stopwatch()..start();
      final request = await client.getUrl(uri);
      request.headers.set('range', 'bytes=$start-${start + length - 1}');
      final response = await request.close();
      if (response.statusCode != 206) {
        await response.drain<void>();
        throw StateError(
          'Synthetic source unavailable: ${response.statusCode}',
        );
      }
      var received = 0;
      await for (final bytes in response) {
        if (initial && received == 0) firstByteMs = watch.elapsedMilliseconds;
        for (var i = 0; i < bytes.length; i++) {
          if (bytes[i] != (start + received + i) % 251) {
            throw StateError('Incorrect cached byte');
          }
        }
        received += bytes.length;
      }
      if (received != length) throw StateError('Truncated cached response');
      return watch.elapsedMilliseconds;
    }

    Future<void> settled() async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((store?.diagnostics['pendingBytes'] as int? ?? 0) > 0) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Cache writes did not settle');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    final initialMs = await fetch(0, _mib, initial: true);
    await settled();
    final repeatStart = scenario == 'disk-fault' ? 3 * _mib ~/ 4 : 0;
    final repeatLength = scenario == 'disk-fault' ? _mib ~/ 4 : _mib;
    if (scenario.contains('overquota')) {
      for (var offset = _mib; offset < total; offset += _mib) {
        await fetch(offset, _mib);
        await settled();
        if (enabled && _diskBytes(diskRoot) > 2 * _mib) {
          throw StateError('Disk quota exceeded');
        }
      }
    }
    if (scenario == 'outage') offline = true;
    final upstreamBeforeRepeat = upstreamBytes;
    final requestsBeforeRepeat = upstreamRequests;
    final repeatWatch = Stopwatch()..start();
    var succeeded = true;
    try {
      await fetch(repeatStart, repeatLength);
    } catch (_) {
      if (scenario != 'outage' || enabled) rethrow;
      succeeded = false;
    }
    repeatWatch.stop();
    await settled();
    if (enabled &&
        !scenario.contains('overquota') &&
        upstreamBytes != upstreamBeforeRepeat) {
      throw StateError('Cached range downloaded twice');
    }
    final diagnostics = proxy.diagnostics;
    final actualDiskBytes = _diskBytes(diskRoot);
    await proxy.close();
    if (enabled &&
        scenario != 'disk-fault' &&
        diskRoot.listSync().whereType<Directory>().isNotEmpty) {
      throw StateError('Session cache was not removed');
    }
    return {
      'scenario': scenario,
      'trial': trial,
      'cache': enabled,
      'firstByteMs': firstByteMs,
      'initialReadMs': initialMs,
      'repeatReadMs': repeatWatch.elapsedMilliseconds,
      'repeatSucceeded': succeeded,
      'upstreamBytes': upstreamBytes,
      'repeatUpstreamBytes': upstreamBytes - upstreamBeforeRepeat,
      'repeatUpstreamRequests': upstreamRequests - requestsBeforeRepeat,
      'rssPeakBytes': rssPeak,
      'actualDiskBytes': actualDiskBytes,
      'diagnostics': diagnostics,
      'cleanup': proxy.diagnostics['cleanup'],
    };
  } finally {
    sampling.cancel();
    client.close(force: true);
    await proxy?.close();
    await server.close(force: true);
    // Only this invocation's unique temporary root is removed.
    await root.delete(recursive: true);
  }
}

int _diskBytes(Directory root) => !root.existsSync()
    ? 0
    : root
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .fold(0, (sum, file) => sum + file.lengthSync());
