import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/cache/cache_crc32.dart';
import 'package:rillight_player/cache_crc32.dart' show cacheCrc32Backend;
import 'package:rillight_player/src/crc32_bindings.dart';

void main() {
  test(
    'native dispatch and software agree at SIMD and unaligned boundaries',
    () {
      // Record the actual path without requiring an ISA on older CI hosts.
      // ignore: avoid_print
      print('Native CRC32 backend: ${cacheCrc32Backend.name}');
      final data = calloc<Uint8>(8192);
      try {
        final bytes = data.asTypedList(8192);
        for (var i = 0; i < bytes.length; i++) {
          bytes[i] = (i * 17 + (i >> 8)) & 255;
        }
        for (final offset in [0, 1, 3, 7, 15, 31]) {
          for (final length in [
            0,
            1,
            3,
            4,
            7,
            8,
            15,
            16,
            31,
            32,
            63,
            64,
            65,
            79,
            80,
            127,
            128,
            255,
            256,
            257,
            4095,
            4096,
            4097,
          ]) {
            final view = Uint8List.sublistView(bytes, offset, offset + length);
            final expected = _referenceCrc32(view);
            final pointer = data + offset;
            expect(nativeCrc32(0, pointer, length), expected);
            expect(nativeCrc32Software(0, pointer, length), expected);
            expect(cacheCrc32(view), expected);
            final split = length ~/ 2;
            final first = nativeCrc32(0, pointer, split);
            expect(
              nativeCrc32(first, pointer + split, length - split),
              expected,
            );
          }
        }
        expect(nativeCrc32(0x87654321, nullptr, 0), 0x87654321);
        expect(nativeCrc32Software(0x87654321, nullptr, 0), 0x87654321);
      } finally {
        calloc.free(data);
      }
    },
  );

  test('bounded native copies preserve CRC across 4 MiB chunk boundaries', () {
    // Independent Python zlib vectors: (i * 17 + (i >> 8)) & 255.
    const vectors = {
      4194303: 0x91286091,
      4194304: 0x1229ab40,
      4194305: 0xa4cc87b6,
      8388621: 0x01ae6dd9,
    };
    final bytes = Uint8List(8388621);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (i * 17 + (i >> 8)) & 255;
    }
    for (final vector in vectors.entries) {
      expect(
        cacheCrc32(Uint8List.sublistView(bytes, 0, vector.key)),
        vector.value,
      );
    }
  });

  test('cache CRC32 preserves standard IEEE tokens and view boundaries', () {
    expect(cacheCrc32(Uint8List(0)), 0);
    expect(
      cacheCrc32(Uint8List.fromList(utf8.encode('123456789'))),
      0xcbf43926,
    );
    final backing = Uint8List.fromList(utf8.encode('xx123456789yy'));
    expect(cacheCrc32(Uint8List.sublistView(backing, 2, 11)), 0xcbf43926);
    expect(
      cacheCrc32(
        Uint8List(4 * 1024 * 1024)..fillRange(0, 4 * 1024 * 1024, 123),
      ),
      3237073340,
    );
  });
}

// Deliberately simple bitwise reference, independent of the native table and
// polynomial folding implementation. This is test-only, never a runtime path.
int _referenceCrc32(Uint8List bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
