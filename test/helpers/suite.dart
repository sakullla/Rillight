import 'dart:io';

import 'suite_manifest.dart';

/// Run during collection so a new case module cannot silently be omitted.
/// Ordinary *_test.dart files remain discoverable by Flutter without this list.
void verifySuiteManifest() {
  final root = Directory('test').absolute;
  final found =
      root
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('_cases.dart'))
          .map(
            (file) =>
                file.path.substring(root.path.length + 1).replaceAll('\\', '/'),
          )
          .toList()
        ..sort();
  if (found.join('\n') != caseModules.join('\n')) {
    throw StateError(
      'Test case modules changed. Run '
      'python tool/test_execution/generate_suites.py before flutter test.',
    );
  }
}
