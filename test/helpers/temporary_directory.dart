import 'dart:async';
import 'dart:io';

/// Cache disposal bounds its UI wait; its disk worker can still be releasing
/// handles afterwards. Only use this for disposable, test-owned directories.
Future<void> deleteTemporaryDirectory(
  Directory directory, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final elapsed = Stopwatch()..start();
  while (true) {
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      if ((code == 2 || (Platform.isWindows && code == 3)) &&
          !await directory.exists()) {
        return;
      }
      // Sharing/lock violations, or a directory still being cleaned by its
      // owner. Permission errors and other failures must remain visible.
      if (!Platform.isWindows ||
          !const {32, 33, 145}.contains(code) ||
          elapsed.elapsed >= timeout) {
        rethrow;
      }
      // Yield to the worker and retry the actual deletion, not a stale stat.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}
