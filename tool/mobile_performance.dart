// Aggregate JSONL records returned by integration_test/mobile_performance.dart.
// Keep cold and warm samples separate; missing or timed-out actions count as
// failures instead of disappearing from latency statistics.
import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln('Usage: dart tool/mobile_performance.dart <samples.jsonl>');
    exitCode = 64;
    return;
  }
  final file = File(arguments.single);
  if (!file.existsSync()) {
    stderr.writeln('Missing samples: ${file.path}');
    exitCode = 1;
    return;
  }
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final line in file.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final value = jsonDecode(line);
    if (value is! Map<String, dynamic>) {
      stderr.writeln('Invalid sample: $line');
      exitCode = 1;
      return;
    }
    final label = value['label'];
    final cache = value['cache'];
    final device = value['device'];
    final build = value['build'];
    final mode = value['buildMode'];
    if (label is! String ||
        !{'cold', 'warm'}.contains(cache) ||
        device is! String ||
        device.isEmpty ||
        build is! String ||
        build.isEmpty ||
        !{'profile', 'release', 'debug'}.contains(mode)) {
      stderr.writeln(
        'Sample needs label, cold/warm cache, device, build and buildMode',
      );
      exitCode = 1;
      return;
    }
    groups
        .putIfAbsent('$label/$cache/$device/$build/$mode', () => [])
        .add(value);
  }
  if (groups.isEmpty) {
    stderr.writeln('No measured samples');
    exitCode = 1;
    return;
  }
  for (final entry in groups.entries) {
    final content = <double>[];
    final operable = <double>[];
    var failures = 0;
    for (final sample in entry.value) {
      final first = sample['firstContentMs'];
      final action = sample['firstOperableMs'];
      if (sample['complete'] != true || first is! num || action is! num) {
        failures++;
        continue;
      }
      content.add(first.toDouble());
      operable.add(action.toDouble());
    }
    stdout.writeln(
      jsonEncode({
        'scenario': entry.key,
        'samples': entry.value.length,
        'failures': failures,
        'firstContentMs': _summary(content),
        'firstOperableMs': _summary(operable),
      }),
    );
  }
}

Map<String, double>? _summary(List<double> values) {
  if (values.isEmpty) return null;
  values.sort();
  double percentile(double quantile) {
    final index = (values.length - 1) * quantile;
    final low = index.floor(), high = index.ceil();
    return values[low] + (values[high] - values[low]) * (index - low);
  }

  return {'median': percentile(0.5), 'p95': percentile(0.95)};
}
