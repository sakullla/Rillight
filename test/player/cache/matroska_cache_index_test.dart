import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/cache/matroska_cache_index.dart';

List<int> uint(int value, [int? width]) {
  var count = width ?? 1;
  while (width == null && value >= (1 << (count * 8))) {
    count++;
  }
  return [for (var i = count - 1; i >= 0; i--) (value >> (i * 8)) & 255];
}

List<int> element(int id, List<int> body) {
  var width = 1;
  while (body.length >= (1 << (width * 7)) - 1) {
    width++;
  }
  return [
    ...uint(id),
    ...uint((1 << (width * 7)) | body.length, width),
    ...body,
  ];
}

(Uint8List, List<int>) fixture({int scale = 1000000}) {
  final info = element(0x1549a966, element(0x2ad7b1, uint(scale)));
  final tracks = element(
    0x1654ae6b,
    element(0xae, [
      ...element(0xd7, [1]),
      ...element(0x83, [1]),
    ]),
  );
  final payload = [...info, ...tracks];
  final positions = <int>[];
  for (final size in [100, 500, 80]) {
    positions.add(payload.length);
    payload.addAll(element(0x1f43b675, List.filled(size, 0)));
  }
  payload.addAll(
    element(0x1c53bb6b, [
      for (var i = 0; i < positions.length; i++)
        ...element(0xbb, [
          ...element(0xb3, uint(i * 10000)),
          ...element(0xb7, [
            ...element(0xf7, [1]),
            ...element(0xf1, uint(positions[i])),
          ]),
        ]),
    ]),
  );
  final segment = element(0x18538067, payload);
  final ebml = element(0x1a45dfa3, []);
  final base = ebml.length + segment.length - payload.length;
  return (
    Uint8List.fromList([...ebml, ...segment]),
    [for (final p in positions) base + p],
  );
}

void main() {
  test('follows an EOF SeekHead to locate cues outside the prefix', () async {
    List<int> head(int target, int offset) => element(
      0x114d9b74,
      element(0x4dbb, [
        ...element(0x53ab, uint(target)),
        ...element(0x53ac, uint(offset, 8)),
      ]),
    );
    final first = head(0x114d9b74, 0);
    final prefix = [
      ...first,
      ...element(0x1549a966, element(0x2ad7b1, uint(1000000))),
      ...element(
        0x1654ae6b,
        element(0xae, [
          ...element(0xd7, [1]),
          ...element(0x83, [1]),
        ]),
      ),
      ...element(0xec, List.filled(70000, 0)),
    ];
    final cues = element(0x1c53bb6b, [
      for (var i = 0; i < 2; i++)
        ...element(0xbb, [
          ...element(0xb3, uint(i * 10000)),
          ...element(0xb7, [
            ...element(0xf7, [1]),
            ...element(0xf1, uint(1000 + i * 1000)),
          ]),
        ]),
    ]);
    final payload = [
      ...head(0x114d9b74, prefix.length + cues.length),
      ...prefix.skip(first.length),
      ...cues,
      ...head(0x1c53bb6b, prefix.length),
    ];
    final bytes = Uint8List.fromList([
      ...element(0x1a45dfa3, []),
      ...element(0x18538067, payload),
    ]);
    final offsets = <int>[];
    final index = await MatroskaCacheIndex.load(
      total: bytes.length,
      read: (offset, length) async {
        offsets.add(offset);
        return Uint8List.sublistView(bytes, offset, offset + length);
      },
    );
    expect(index?.points.length, 2);
    expect(offsets.any((offset) => offset > 64 * 1024), true);
  });

  test('variable bitrate clusters map via cues, not file percentage', () async {
    final (bytes, positions) = fixture();
    final index = await MatroskaCacheIndex.load(
      total: bytes.length,
      read: (offset, length) async =>
          Uint8List.sublistView(bytes, offset, offset + length),
    );
    expect(index, isNotNull);
    final partial = index!.ranges([
      CachedByteRange(positions[1], positions[2] + 5),
    ], const Duration(seconds: 30));
    expect(partial.map((r) => (r.start.inSeconds, r.end.inSeconds)), [
      (10, 20),
    ]);
    final tail = index.ranges([
      CachedByteRange(positions[1], bytes.length),
    ], const Duration(seconds: 30));
    expect(tail.map((r) => (r.start.inSeconds, r.end.inSeconds)), [(10, 30)]);
    final holes = index.ranges([
      CachedByteRange(positions[0], positions[1]),
      CachedByteRange(positions[2], bytes.length),
    ], const Duration(seconds: 30));
    expect(holes.map((r) => (r.start.inSeconds, r.end.inSeconds)), [
      (0, 10),
      (20, 30),
    ]);
  });

  test(
    'timestamp scale is honored and unavailable metadata is not guessed',
    () async {
      final (bytes, positions) = fixture(scale: 2000000);
      final index = await MatroskaCacheIndex.load(
        total: bytes.length,
        read: (offset, length) async =>
            Uint8List.sublistView(bytes, offset, offset + length),
      );
      expect(
        index!
            .ranges([
              CachedByteRange(positions[1], bytes.length),
            ], const Duration(seconds: 60))
            .single
            .start,
        const Duration(seconds: 20),
      );
      expect(
        await MatroskaCacheIndex.load(
          total: bytes.length,
          read: (_, _) async => null,
        ),
        null,
      );
      expect(
        await MatroskaCacheIndex.load(
          total: 16,
          read: (_, length) async => Uint8List(length),
        ),
        null,
      );
    },
  );
}
