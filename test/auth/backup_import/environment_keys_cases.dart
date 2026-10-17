import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/backup_import/environment_keys.dart';

void main() {
  group('environment backup import keys', () {
    test('empty defines keep every key absent', () {
      final keys = buildEnvironmentBackupImportKeys();
      expect(keys.hillsDataKey, isNull);
      expect(keys.rodelCommonKeysBySource, isEmpty);
      expect(keys.rodelBackupConfigKeys, isEmpty);
    });

    test('valid hex defines populate each key entry', () {
      const syntheticCommon = 'synthetic-common-key-bytes-ok!!';
      final keys = buildEnvironmentBackupImportKeys(
        hillsHex: 'ab' * 32,
        commonHex: utf8
            .encode(syntheticCommon)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        rpbHex: '0123456789abcdef0123456789abcdef',
      );
      expect(keys.hillsDataKey, hasLength(32));
      expect(
        keys.rodelCommonKeysBySource['RodelPlayer'],
        utf8.encode(syntheticCommon),
      );
      expect(keys.rodelBackupConfigKeys.single, hasLength(16));
      expect(keys.rodelBackupConfigKeys.single.first, 0x01);
    });

    test('malformed hex falls back to absent instead of throwing', () {
      expect(
        buildEnvironmentBackupImportKeys(hillsHex: 'zz').hillsDataKey,
        isNull,
      );
      expect(
        buildEnvironmentBackupImportKeys(rpbHex: 'abc').rodelBackupConfigKeys,
        isEmpty,
      );
    });
  });
}
