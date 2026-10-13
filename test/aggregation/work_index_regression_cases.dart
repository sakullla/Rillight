import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';

import '../helpers/work_index_reference.dart';

void main() {
  test(
    'indexed grouping matches exhaustive grouping through pages, edits and removals',
    () {
      for (var seed = 0; seed < 40; seed++) {
        final random = Random(seed);
        final sources = [
          for (var i = 0; i < 48; i++)
            WorkSource(
              reference: SourceReference(
                account: SourceAccount(
                  region: random.nextInt(4) == 0
                      ? AccessRegion.private
                      : AccessRegion.ordinary,
                  configuredServerId: 'server-${i % 3}',
                  verifiedServerId: 'verified-${i % 3}',
                  userId: 'u',
                ),
                itemId: 'item-${i ~/ 6}',
                mediaSourceId: i % 2 == 0 ? null : 'v${i % 3}',
              ),
              type: ['Movie', 'Series', 'Episode'][random.nextInt(3)],
              title: 'Title ${random.nextInt(5)}',
              year: random.nextBool() ? null : 2020 + random.nextInt(3),
              providerIds: {
                if (random.nextBool()) 'tmdb': '${random.nextInt(5) + 1}',
                if (random.nextBool()) 'imdb': 'tt${random.nextInt(5)}',
                if (random.nextBool()) 'tvdb': '${random.nextInt(5) + 1}',
                if (random.nextBool()) 'custom': '${random.nextInt(3)}',
              },
            ),
        ]..shuffle(random);
        final actual = WorkIndex(), expected = ReferenceWorkIndex();

        void verify() {
          expect(
            [
              for (final group in actual.groups)
                [
                  group.key,
                  group.sources.map((s) => s.reference.key).toList(),
                  [
                    for (final link in group.confirmations)
                      [
                        link.a.key,
                        link.b.key,
                        link.decision.reason,
                        link.decision.providers,
                      ],
                  ],
                ],
            ],
            [
              for (final group in expected.groups)
                [
                  group.key,
                  group.sources.map((s) => s.reference.key).toList(),
                  [
                    for (final link in group.confirmations)
                      [
                        link.a.key,
                        link.b.key,
                        link.decision.reason,
                        link.decision.providers,
                      ],
                  ],
                ],
            ],
            reason: 'seed $seed',
          );
          for (final source in sources) {
            for (final ref in [source.reference, source.reference.item]) {
              expect(
                actual.groupFor(ref)?.key,
                expected.groupFor(ref)?.key,
                reason: 'seed $seed anchor ${ref.key}',
              );
              expect(
                actual.groupForKey(ref.key)?.key,
                expected.groupForKey(ref.key)?.key,
              );
            }
          }
        }

        for (var start = 0; start < sources.length; start += 8) {
          final page = sources.skip(start).take(8);
          actual.upsert(page);
          expected.upsert(page);
          verify();
        }
        final removed = sources.take(12).map((s) => s.reference).toSet();
        actual.removeWhere(removed.contains);
        expected.removeWhere(removed.contains);
        verify();
        final edits = sources
            .take(16)
            .map(
              (source) => WorkSource(
                reference: source.reference,
                type: 'Movie',
                title: 'Updated',
                year: 2025,
                providerIds: const {'tmdb': '25', 'imdb': 'tt25'},
              ),
            )
            .toList();
        actual.upsert(edits);
        expected.upsert(edits);
        verify();
        actual.removeWhere((_) => true);
        expected.removeWhere((_) => true);
        verify();
      }
    },
  );
}
