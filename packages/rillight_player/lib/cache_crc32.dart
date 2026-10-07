import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/crc32_bindings.dart';

enum CacheCrc32Backend { software, armCrc32, x86Pclmul }

/// CPU capability, independent of device model and player lifecycle.
CacheCrc32Backend get cacheCrc32Backend =>
    CacheCrc32Backend.values[nativeCrc32Backend()];

/// IEEE CRC32, compatible with previously persisted cache block checksums.
/// All platforms use native code; supported CPUs accelerate the same polynomial.
int cacheCrc32(Uint8List bytes) {
  if (bytes.isEmpty) return 0;
  const chunkBytes = 4 * 1024 * 1024;
  final size = bytes.length < chunkBytes ? bytes.length : chunkBytes;
  final data = malloc<Uint8>(size);
  try {
    final buffer = data.asTypedList(size);
    var crc = 0;
    for (var offset = 0; offset < bytes.length; offset += size) {
      final remaining = bytes.length - offset;
      final length = remaining < size ? remaining : size;
      // setRange respects typed-data views and their byte offsets.
      buffer.setRange(0, length, bytes, offset);
      crc = nativeCrc32(crc, data, length);
    }
    return crc;
  } finally {
    malloc.free(data);
  }
}
