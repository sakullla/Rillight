import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/file_import.dart';
import 'package:rillight/auth/backup_import/backup_import.dart';
import 'package:rillight/auth/backup_import/backup_import_flow.dart';
import 'package:rillight/auth/backup_import/backup_import_models.dart';

import '../auth/backup_import/backup_import_cases.dart' as fixtures;

void main() {
  for (final size in [0, 3, 16]) {
    test('reads Android memory file of $size bytes within limit', () async {
      final bytes = Uint8List.fromList(List.generate(size, (i) => i));
      final file = await PickedAppFile.fromXFile(
        XFile.fromData(bytes, path: 'content://documents/backup.json'),
      );
      expect(await file.readBytes(16), bytes);
    });
  }

  test(
    'rejects oversized memory files even with stale size metadata',
    () async {
      final file = await PickedAppFile.fromXFile(
        XFile.fromData(Uint8List(17), length: 1),
      );
      await expectLater(
        file.readBytes(16),
        throwsA(isA<AppFileTooLargeException>()),
      );
    },
  );

  test('reads path-backed files and still rejects oversized files', () async {
    final directory = await Directory.systemTemp.createTemp('file-import-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/backup.json');
    await source.writeAsBytes([1, 2, 3]);
    final file = await PickedAppFile.fromXFile(XFile(source.path));
    expect(await file.readBytes(16), [1, 2, 3]);
    expect(await file.readBytes(3), [1, 2, 3]);
    await expectLater(
      file.readBytes(2),
      throwsA(isA<AppFileTooLargeException>()),
    );
    await source.delete();
    await expectLater(file.readBytes(16), throwsA(isA<AppFileReadException>()));
  });

  test(
    'unknown lengths retain the limit and cancel oversized streams',
    () async {
      final source = _UnknownLengthFile();
      final file = await PickedAppFile.fromXFile(source);
      expect(file.length, isNull);
      await expectLater(
        file.readBytes(3),
        throwsA(isA<AppFileTooLargeException>()),
      );
      expect(source.cancelled, isTrue);
      expect(source.chunksRead, 2);
    },
  );

  test('Android Hills backup reaches parsing instead of unreadable', () async {
    final bytes = await fixtures.buildHillsBackup([
      fixtures.hillsServer(
        displayName: 'Synthetic server',
        serverUrl: 'http://192.0.2.10:8096',
      ),
    ]);
    final file = await PickedAppFile.fromXFile(
      XFile.fromData(
        Uint8List.fromList(bytes),
        path: 'content://documents/hills.json',
      ),
    );
    final parsed = await parseAndCommitBackup(
      file,
      commit: (_) async => throw StateError('Missing key must not commit'),
    );
    expect(parsed.status, BackupImportFlowStatus.containerRejected);
    expect(
      parsed.containerStatus,
      BackupImportContainerStatus.decryptionKeyUnavailable,
    );
    // Verify the same bytes survive the real reader and decrypt with a test key.
    final result = await parseBackupForImport(
      await file.readBytes(const BackupImportLimits().maxInputBytes),
      keys: fixtures.hillsKeys(),
    );
    expect(result.status, BackupImportContainerStatus.ready);
    expect(result.drafts, hasLength(1));
  });
}

class _UnknownLengthFile extends XFile {
  _UnknownLengthFile() : super('unknown.json');

  bool cancelled = false;
  int chunksRead = 0;

  @override
  Future<int> length() async => throw const FileSystemException('Unavailable');

  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    try {
      for (var i = 0; i < 3; i++) {
        chunksRead++;
        yield Uint8List.fromList([1, 2]);
      }
    } finally {
      cancelled = true;
    }
  }
}
