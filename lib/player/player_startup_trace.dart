import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Opt-in local timing only. Callers pass fixed phase names and numeric
/// counters; never URLs, item names, credentials or exception messages.
class PlayerStartupTrace {
  static final String? _path = Platform.environment['RILLIGHT_STARTUP_TRACE'];
  static final Stopwatch _watch = Stopwatch()..start();
  static IOSink? _sink;

  static void record(String phase, [Map<String, num> counters = const {}]) {
    if (kDebugMode &&
        const bool.fromEnvironment('RILLIGHT_STARTUP_TRACE_LOG')) {
      debugPrintSynchronously(
        'RillightStartup ${jsonEncode({'phase': phase, 'elapsedMs': _watch.elapsedMilliseconds, ...counters})}',
      );
    }
    final path = _path;
    if (path == null || path.isEmpty) return;
    try {
      if (_sink == null) {
        _sink = File('$path.$pid.jsonl').openWrite(mode: FileMode.append);
        _sink!.done.catchError((Object _) {});
      }
      _sink!.writeln(
        jsonEncode({
          'at': DateTime.now().toUtc().toIso8601String(),
          'elapsedMs': _watch.elapsedMilliseconds,
          'phase': phase,
          ...counters,
        }),
      );
    } catch (_) {
      // Optional timing must never change playback behavior.
    }
  }
}
