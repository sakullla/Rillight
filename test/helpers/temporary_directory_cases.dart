import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'temporary_directory.dart';

void main() {
  test(
    'temporary directory deletion tolerates already removed roots',
    () async {
      final root = await Directory.systemTemp.createTemp('rillight-cleanup-');
      await deleteTemporaryDirectory(root);
      await deleteTemporaryDirectory(root);
      expect(await root.exists(), isFalse);
    },
  );

  test(
    'temporary directory deletion waits for a Windows handle release',
    () async {
      final root = await Directory.systemTemp.createTemp('rillight-cleanup-');
      final handle = await File('${root.path}/held').open(mode: FileMode.write);
      var released = false;
      addTearDown(() async {
        if (!released) await handle.close();
        if (await root.exists()) await root.delete(recursive: true);
      });
      // Establish a real sharing violation before exercising the retry path.
      await expectLater(
        root.delete(recursive: true),
        throwsA(isA<FileSystemException>()),
      );
      final release = Timer(const Duration(milliseconds: 100), () {
        handle.closeSync();
        released = true;
      });
      addTearDown(release.cancel);
      await deleteTemporaryDirectory(root);
      expect(released, isTrue);
      expect(await root.exists(), isFalse);
    },
    skip: !Platform.isWindows,
  );

  test('persistent Windows locks still fail at the cleanup deadline', () async {
    final root = await Directory.systemTemp.createTemp('rillight-cleanup-');
    final handle = await File('${root.path}/held').open(mode: FileMode.write);
    try {
      await expectLater(
        deleteTemporaryDirectory(
          root,
          timeout: const Duration(milliseconds: 40),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await root.exists(), isTrue);
    } finally {
      await handle.close();
      await root.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
}
