import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/cache/directory_inventory.dart';

void main() {
  test('repeated dense inventories remain complete', () {
    final root = Directory.systemTemp.createTempSync(
      'rillight-inventory-dense-',
    );
    try {
      for (var i = 0; i < 128; i++) {
        File('${root.path}/$i.block').writeAsBytesSync(List.filled(i + 1, 7));
      }
      for (var iteration = 0; iteration < 100; iteration++) {
        final inventory = readCacheDirectory(root, maxEntries: 128);
        expect(inventory.entries, hasLength(128));
        expect(inventory.stats.length, 128);
        expect(
          inventory.stats.values.fold<int>(0, (sum, stat) => sum + stat.size),
          8256,
        );
      }
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test(
    'inventory uses actual sizes, refreshes mutations and excludes children',
    () {
      final root = Directory.systemTemp.createTempSync('rillight-inventory-');
      try {
        final file = File('${root.path}/中文-1-deadbeef.block')
          ..writeAsBytesSync(List.filled(4096, 7));
        final child = Directory('${root.path}/child')..createSync();
        File('${child.path}/nested').writeAsBytesSync(List.filled(8192, 1));
        final first = readCacheDirectory(root, maxEntries: 2);
        expect(first.entries.length, 2);
        expect(first.stats.values.single.size, 4096);
        expect(
          first.stats.values.single.modified.microsecondsSinceEpoch,
          file.lastModifiedSync().microsecondsSinceEpoch,
        );
        file.writeAsBytesSync([9]);
        final second = readCacheDirectory(root, maxEntries: 2);
        expect(second.stats.values.single.size, 1);
        expect(
          () => readCacheDirectory(root, maxEntries: 1),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );
}
