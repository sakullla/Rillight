import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'src/directory_bindings.dart';

/// Fresh, bounded POSIX metadata; file sizes are read from the filesystem.
List<({String name, int kind, int size, int modifiedMicros, int changedMicros})>
readNativeCacheDirectory(String path, int maxEntries) {
  if (maxEntries < 0 || maxEntries > 8192) {
    throw ArgumentError.value(maxEntries, 'maxEntries');
  }
  return using((arena) {
    final entries = arena<NativeDirectoryEntry>(
      maxEntries == 0 ? 1 : maxEntries,
    );
    final count = nativeReadDirectory(
      path.toNativeUtf8(allocator: arena).cast(),
      entries,
      maxEntries,
    );
    if (count < 0) {
      throw FileSystemException('Cache directory enumeration failed', path);
    }
    return [
      for (var i = 0; i < count; i++)
        (
          name: utf8.decode(
            entries[i].name.elements.takeWhile((byte) => byte != 0).toList(),
          ),
          kind: entries[i].kind,
          size: entries[i].size,
          modifiedMicros: entries[i].modifiedMicros,
          changedMicros: entries[i].changedMicros,
        ),
    ];
  });
}
