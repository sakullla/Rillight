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
    final uiFrames = <double>[];
    final rasterFrames = <double>[];
    var failures = 0;
    var missingFrameData = 0;
    var overBudgetFrames = 0;
    var measuredFrames = 0;
    double? frameBudgetMs;
    for (final sample in entry.value) {
      final first = sample['firstContentMs'];
      final action = sample['firstOperableMs'];
      if (sample['complete'] != true || first is! num || action is! num) {
        failures++;
        continue;
      }
      content.add(first.toDouble());
      operable.add(action.toDouble());
      final budget = sample['frameBudgetMs'];
      final ui = sample['uiFrameMs'];
      final raster = sample['rasterFrameMs'];
      if (budget is! num ||
          budget <= 0 ||
          ui is! List ||
          raster is! List ||
          ui.isEmpty ||
          ui.length != raster.length ||
          ui.any((value) => value is! num || value < 0) ||
          raster.any((value) => value is! num || value < 0)) {
        missingFrameData++;
        continue;
      }
      final currentBudget = budget.toDouble();
      if (frameBudgetMs != null &&
          (frameBudgetMs - currentBudget).abs() > 0.01) {
        stderr.writeln('Mixed frame budgets in ${entry.key}');
        exitCode = 1;
        return;
      }
      frameBudgetMs = currentBudget;
      for (var i = 0; i < ui.length; i++) {
        final uiMs = (ui[i] as num).toDouble();
        final rasterMs = (raster[i] as num).toDouble();
        uiFrames.add(uiMs);
        rasterFrames.add(rasterMs);
        measuredFrames++;
        if (uiMs > currentBudget || rasterMs > currentBudget) {
          overBudgetFrames++;
        }
      }
    }
    stdout.writeln(
      jsonEncode({
        'scenario': entry.key,
        'samples': entry.value.length,
        'failures': failures,
        'firstContentMs': _summary(content),
        'firstOperableMs': _summary(operable),
        'frameBudgetMs': frameBudgetMs,
        'measuredFrames': measuredFrames,
        'missingFrameDataSamples': missingFrameData,
        'uiFrameMs': _summary(uiFrames),
        'rasterFrameMs': _summary(rasterFrames),
        'overBudgetFrames': overBudgetFrames,
        'overBudgetRate': measuredFrames == 0
            ? null
            : overBudgetFrames / measuredFrames,
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
