import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';

void main() {
  test(
    'range sweep and binary reads preserve exhaustive overlap selection',
    () async {
      for (var seed = 0; seed < 24; seed++) {
        final cache = await SessionByteCache.open(
          memoryLimitBytes: 64 * 1024,
          diskLimitBytes: 0,
        );
        final blocks = <int, Uint8List>{};
        final random = Random(seed);
        try {
          for (var i = 0; i < 96; i++) {
            final offset = i < 16 ? i * 16 : random.nextInt(256);
            final length = i < 16 ? 16 : 1 + random.nextInt(40);
            final bytes = Uint8List.fromList(List.filled(length, i));
            blocks.remove(offset);
            blocks[offset] = bytes;
            await cache.put(
              resource: 'video',
              generation: 1,
              offset: offset,
              bytes: bytes,
            );
          }
          // These larger overlapping blocks must not enter this lease.
          await cache.put(
            resource: 'other',
            generation: 1,
            offset: 0,
            bytes: Uint8List(512),
          );
          await cache.put(
            resource: 'video',
            generation: 2,
            offset: 0,
            bytes: Uint8List(512),
          );
          for (final range in [(0, 256), (31, 80), (170, 48), (300, 12)]) {
            final expected = <MapEntry<int, Uint8List>>[];
            var cursor = range.$1;
            var complete = true;
            while (cursor < range.$1 + range.$2) {
              MapEntry<int, Uint8List>? selected;
              for (final block in blocks.entries) {
                if (block.key > cursor ||
                    block.key + block.value.length <= cursor) {
                  continue;
                }
                if (selected == null ||
                    block.key + block.value.length >
                        selected.key + selected.value.length) {
                  selected = block;
                }
              }
              if (selected == null) {
                complete = false;
                break;
              }
              expected.add(selected);
              cursor = selected.key + selected.value.length;
            }
            final lease = await cache.protectRange(
              resource: 'video',
              generation: 1,
              offset: range.$1,
              length: range.$2,
            );
            expect(lease != null, complete, reason: 'seed $seed range $range');
            if (lease == null) continue;
            try {
              // Arbitrary-order reads include overlaps, exact boundaries and misses.
              final offsets = [for (var i = -1; i <= 300; i++) i]
                ..shuffle(random);
              for (final offset in offsets) {
                final selected = expected
                    .where(
                      (b) => b.key <= offset && offset < b.key + b.value.length,
                    )
                    .firstOrNull;
                final read = await lease.read(offset, maxLength: 5);
                final start = selected == null ? 0 : offset - selected.key;
                expect(
                  read?.bytes,
                  selected?.value.sublist(
                    start,
                    min(start + 5, selected.value.length),
                  ),
                  reason: 'seed $seed offset $offset',
                );
              }
            } finally {
              await lease.close();
            }
            expect(await lease.read(range.$1), isNull);
          }
          expect(cache.diagnostics['protectedRanges'], 0);
        } finally {
          await cache.close();
        }
      }
    },
  );
}
