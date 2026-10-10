import 'dart:ffi';
import 'dart:typed_data';

import 'src/crc32_bindings.dart';

enum CacheCrc32Backend { software, armCrc32, x86Pclmul }

/// CPU capability, independent of device model and player lifecycle.
CacheCrc32Backend get cacheCrc32Backend => CacheCrc32Backend.values[_backend];

final int _backend = nativeCrc32Backend();

/// IEEE CRC32, compatible with previously persisted cache block checksums.
/// All platforms use native code; supported CPUs accelerate the same polynomial.
int cacheCrc32(Uint8List bytes) {
  if (bytes.isEmpty) return 0;
  // Borrow typed-data storage only during a short leaf call. No native staging
  // allocation or whole-block copy; the VM pins the view for this invocation.
  // Bound the call even on the software path to avoid delaying another
  // isolate's GC behind one multi-megabyte checksum.
  const chunkBytes = 64 * 1024;
  final backend = _backend;
  var crc = 0;
  for (var offset = 0; offset < bytes.length; offset += chunkBytes) {
    final end = (offset + chunkBytes).clamp(0, bytes.length);
    final chunk = offset == 0 && end == bytes.length
        ? bytes
        : Uint8List.sublistView(bytes, offset, end);
    crc = nativeCrc32Chunk(crc, chunk.address, chunk.length, backend);
  }
  return crc;
}
