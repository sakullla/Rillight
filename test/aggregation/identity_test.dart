import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/emby/emby_models.dart';

SourceAccount account(
  String server, {
  AccessRegion region = AccessRegion.ordinary,
  String user = 'u',
}) => SourceAccount(
  region: region,
  configuredServerId: server,
  verifiedServerId: 'verified-$server',
  userId: user,
);
SourceReference ref(String server, {String id = 'same', String? version}) =>
    SourceReference(
      account: account(server),
      itemId: id,
      mediaSourceId: version,
    );
WorkSource work(
  String server, {
  Map<String, String> ids = const {'Tmdb': '42'},
  int? year = 2020,
  String type = 'Movie',
  String title = 'Title',
  SourceReference? reference,
}) => WorkSource(
  reference: reference ?? ref(server),
  type: type,
  title: title,
  year: year,
  providerIds: ids,
);

void main() {
  test(
    'reference equality includes region, configured/verified server, account, item and version',
    () {
      final ordinary = ref('a');
      final references = [
        ordinary,
        ref('b'),
        ref('a', version: 'v1'),
        ref('a', version: 'v2'),
        SourceReference(
          account: account('a', user: 'other'),
          itemId: 'same',
        ),
        SourceReference(
          account: account('a', region: AccessRegion.private),
          itemId: 'same',
        ),
        const SourceReference(
          account: SourceAccount(
            region: AccessRegion.ordinary,
            configuredServerId: 'a',
            verifiedServerId: 'different',
            userId: 'u',
          ),
          itemId: 'same',
        ),
      ];
      expect(references.toSet(), hasLength(7));
      expect(references.map((r) => r.key).toSet(), hasLength(7));
      expect(ref('a', version: 'v1').item, ordinary);
    },
  );

  test(
    'reliable normalized identity confirms even different titles; page duplicates do not add sources',
    () {
      final index = WorkIndex()
        ..upsert([
          work('a', ids: {'TMDB': '0042'}),
          work('b', title: 'Translated'),
        ]);
      index.upsert([work('b', title: 'Translated')]);
      expect(index.groups, hasLength(1));
      expect(index.groups.single.sources, hasLength(2));
      expect(index.groups.single.confirmations.single.decision.providers, [
        'tmdb',
      ]);
    },
  );

  test(
    'title-only candidates, bare id and unknown external provider never confirm',
    () {
      final a = work('a', ids: {});
      final b = work('b', ids: {});
      final index = WorkIndex()..upsert([a, b]);
      expect(index.groups, hasLength(2));
      expect(index.candidatesFor(a).single.reference, b.reference);
      expect(compareWorks(a, b).reason, MatchReason.titleOnly);
      expect(
        compareWorks(
          work('a', ids: {'custom': 'x'}),
          work('b', ids: {'custom': 'x'}),
        ).confirmed,
        isFalse,
      );
      expect(
        compareWorks(
          work('a', ids: {'Tmdb': '42'}),
          work('b', ids: {'Imdb': 'tt42'}),
        ).confirmed,
        isFalse,
      );
      expect(
        compareWorks(
          work('a', ids: {'Tmdb': 'bad'}),
          work('b', ids: {'Tmdb': 'bad'}),
        ).confirmed,
        isFalse,
      );
      expect(
        () => work('a', ids: {'Tmdb': '42', 'tmdb': '43'}),
        throwsFormatException,
      );
    },
  );

  test('known provider/year/type/region conflicts beat common identity', () {
    final a = work('a', ids: {'Tmdb': '42', 'Imdb': 'tt1'});
    expect(
      compareWorks(a, work('b', ids: {'Tmdb': '42', 'Imdb': 'tt2'})).reason,
      MatchReason.providerConflict,
    );
    expect(
      compareWorks(a, work('b', year: 2021)).reason,
      MatchReason.yearConflict,
    );
    expect(
      compareWorks(a, work('b', type: 'Series')).reason,
      MatchReason.typeConflict,
    );
    expect(
      compareWorks(
        a,
        work(
          'b',
          reference: SourceReference(
            account: account('b', region: AccessRegion.private),
            itemId: 'same',
          ),
        ),
      ).reason,
      MatchReason.regionConflict,
    );
    expect(compareWorks(a, work('b', year: null)).confirmed, isTrue);
  });

  test('chain conflict is not swallowed; paging order is deterministic', () {
    final sources = [
      work('a', ids: {'Tmdb': '42', 'Imdb': 'tt1'}),
      work('b', ids: {'Tmdb': '42'}),
      work('c', ids: {'Tmdb': '42', 'Imdb': 'tt2'}),
    ];
    final index = WorkIndex()..upsert(sources);
    final reversed = WorkIndex()..upsert(sources.reversed);
    expect(index.groups, hasLength(2));
    expect(index.groups.map((g) => g.key), reversed.groups.map((g) => g.key));
    for (final group in index.groups) {
      for (final a in group.sources) {
        for (final b in group.sources) {
          expect(compareWorks(a, b).kind, isNot(MatchKind.conflict));
        }
      }
    }
  });

  test(
    'nonconflicting provider bridge joins partitions without losing references',
    () {
      final a = work('a', ids: {'Tmdb': '42'});
      final b = work('b', ids: {'Imdb': 'tt1'});
      final c = work('c', ids: {'Tmdb': '42', 'Imdb': 'tt1'});
      final index = WorkIndex()..upsert([a, b]);
      expect(index.groups, hasLength(2));
      index.upsert([c]);
      expect(index.groups, hasLength(1));
      expect(index.groupFor(b.reference)!.sources, hasLength(3));
      expect(index.groups.single.confirmations, hasLength(2));
    },
  );

  test(
    'changed metadata splits groups and source anchored records are not cloned',
    () {
      final index = WorkIndex()..upsert([work('a'), work('b')]);
      final anchor = index.groups.single.sources.first.reference;
      final record = {anchor: 123};
      index.upsert([
        work('b', ids: {'Tmdb': '99'}),
      ]);
      expect(index.groups, hasLength(2));
      expect(index.groupFor(anchor)!.contains(anchor), isTrue);
      expect(record, {anchor: 123});
      index.removeWhere((r) => r.account == account('b'));
      expect(index.groups.single.sources.single.reference, ref('a'));
    },
  );

  test(
    'late earlier source keeps card key and retired merge aliases survive a split',
    () {
      final index = WorkIndex()..upsert([work('z')]);
      final oldKey = index.groups.single.key;
      index.upsert([work('a')]);
      expect(index.groups.single.key, oldKey);
      expect(index.groupForKey(oldKey)!.contains(ref('z')), isTrue);
      index.upsert([
        work('z', ids: {'Tmdb': '99'}),
      ]);
      expect(index.groups, hasLength(2));
      expect(index.groupForKey(oldKey)!.sources.single.reference, ref('z'));
      expect(
        index.groupForKey(ref('a').key)!.sources.single.reference,
        ref('a'),
      );
      index.removeWhere((r) => r == ref('z'));
      expect(index.groupForKey(oldKey), isNull);
    },
  );

  test(
    'versions of the same scoped item retain separate references in one work',
    () {
      final index = WorkIndex()
        ..upsert([
          work(
            'a',
            ids: {},
            reference: ref('a', version: 'v1'),
          ),
          work(
            'a',
            ids: {},
            reference: ref('a', version: 'v2'),
          ),
          work(
            'b',
            ids: {},
            reference: ref('b', version: 'v1'),
          ),
        ]);
      expect(index.groups, hasLength(2));
      expect(index.groupFor(ref('a'))!.sources, hasLength(2));
      expect(
        index.groupFor(ref('a'))!.confirmations.single.decision.reason,
        MatchReason.sameSourceItem,
      );
    },
  );

  test('conflicting versions resolve only their full source anchors', () {
    final v1 = ref('a', version: 'v1');
    final v2 = ref('a', version: 'v2');
    final index = WorkIndex()
      ..upsert([
        work('a', reference: v1),
        work('a', reference: v2, ids: {'Tmdb': '99'}),
      ]);
    expect(index.groups, hasLength(2));
    final first = index.groupFor(v1)!;
    final second = index.groupFor(v2)!;
    expect(first.sources.single.reference, v1);
    expect(second.sources.single.reference, v2);
    expect(first.contains(v2), isFalse);
    expect(second.contains(v1), isFalse);
    expect(index.groupFor(ref('a')), isNull);
    expect(index.groupForKey(v1.key), same(first));
    expect(index.groupForKey(v2.key), same(second));

    index.removeWhere((r) => r == v1);
    expect(index.groupFor(v1), isNull);
    expect(index.groupForKey(v1.key), isNull);
    expect(index.groups.single.contains(v1), isFalse);
    expect(index.groupFor(v2)!.sources.single.reference, v2);
    expect(index.groupFor(ref('a')), same(index.groupFor(v2)));
  });

  test('an explicit item source cannot hide conflicting version groups', () {
    final item = ref('a');
    final version = ref('a', version: 'v2');
    final index = WorkIndex()
      ..upsert([
        work('a', reference: item),
        work('a', reference: version, ids: {'Tmdb': '99'}),
      ]);
    expect(index.groups, hasLength(2));
    expect(index.groupFor(item), isNull);
    expect(index.groupForKey(item.key)!.sources.single.reference, item);
    expect(index.groupFor(version)!.sources.single.reference, version);
  });

  test('merged versions do not resurrect a removed or unknown version', () {
    final v1 = ref('a', version: 'v1');
    final v2 = ref('a', version: 'v2');
    final index = WorkIndex()
      ..upsert([work('a', reference: v1), work('a', reference: v2)]);
    expect(index.groupFor(v1), same(index.groupFor(v2)));
    expect(index.groupFor(ref('a')), same(index.groupFor(v2)));
    index.removeWhere((r) => r == v1);
    expect(index.groupFor(v1), isNull);
    expect(index.groupFor(ref('a', version: 'missing')), isNull);
    expect(index.groups.single.contains(v1), isFalse);
    expect(index.groupFor(v2)!.contains(v2), isTrue);
    expect(index.groupFor(ref('a'))!.contains(ref('a')), isTrue);
  });

  group('episode lookup', () {
    late WorkGroup series;
    setUp(() {
      series =
          (WorkIndex()..upsert([
                work('a', type: 'Series'),
                work('b', type: 'Series'),
              ]))
              .groups
              .single;
    });
    EpisodeSource episode(
      String server, {
      int? season = 1,
      int? number = 2,
      bool? special = false,
      String? scheme = 'aired',
      String seriesId = 'same',
      Map<String, String> ids = const {},
    }) => EpisodeSource(
      reference: ref(server, id: 'ep-$season-$number'),
      series: ref(server, id: seriesId),
      season: season,
      episode: number,
      isSpecial: special,
      numberingScheme: scheme,
      providerIds: ids,
    );
    EpisodeLookup lookup(
      EpisodeSource origin,
      List<EpisodeSource> targets, {
      bool complete = true,
      bool success = true,
    }) => locateEpisode(
      series: series,
      origin: origin,
      targetAccount: account('b'),
      available: targets,
      complete: complete,
      querySucceeded: success,
    );
    test(
      'exact episode and duplicate pages confirmed, never neighboring episode',
      () {
        final target = episode('b');
        final result = lookup(episode('a'), [target, target]);
        expect(result.status, EpisodeLookupStatus.confirmed);
        expect(result.source, same(target));
        final missing = lookup(episode('a'), [episode('b', number: 3)]);
        expect(missing.status, EpisodeLookupStatus.missing);
        expect(missing.source, isNull);
      },
    );
    test('episode series versions require exact group membership', () {
      final a = ref('a', version: 'series-v1');
      final b = ref('b', version: 'series-v1');
      final index = WorkIndex()
        ..upsert([
          work('a', type: 'Series', reference: a),
          work('b', type: 'Series', reference: b),
        ]);
      series = index.groups.single;
      // Emby supplies item-only SeriesId, so versions in one confirmed group
      // must still accept their parent item reference.
      expect(
        lookup(episode('a'), [episode('b')]).status,
        EpisodeLookupStatus.confirmed,
      );
      EpisodeSource withSeries(SourceReference parent) => EpisodeSource(
        reference: ref('b', id: 'episode'),
        series: parent,
        season: 1,
        episode: 2,
        isSpecial: false,
        numberingScheme: 'aired',
      );
      expect(
        lookup(episode('a'), [withSeries(b)]).status,
        EpisodeLookupStatus.confirmed,
      );
      expect(
        lookup(episode('a'), [withSeries(ref('b', version: 'removed'))]).status,
        EpisodeLookupStatus.uncertain,
      );
      expect(
        lookup(episode('a'), [withSeries(ref('b', version: 'removed'))]).source,
        isNull,
      );
    });
    test(
      'specials cannot match ordinary episodes and malformed special boundary is uncertain',
      () {
        expect(
          lookup(episode('a', season: 0, special: true), [episode('b')]).status,
          EpisodeLookupStatus.missing,
        );
        expect(
          lookup(episode('a', season: 0, special: true), [
            episode('b', season: 0, special: true),
          ]).status,
          EpisodeLookupStatus.confirmed,
        );
        expect(
          lookup(episode('a', season: 0), [episode('b', season: 0)]).source,
          isNull,
        );
      },
    );
    test(
      'unconfirmed series, numbering, conflicts and incomplete/failed query never resume',
      () {
        for (final target in [
          episode('b', seriesId: 'unconfirmed'),
          episode('b', scheme: null),
          episode('b', scheme: 'dvd'),
          episode('b', number: null),
        ]) {
          final result = lookup(episode('a'), [target]);
          expect(result.status, EpisodeLookupStatus.uncertain);
          expect(result.source, isNull);
        }
        expect(
          lookup(episode('a', ids: {'Tvdb': '1'}), [
            episode('b', ids: {'Tvdb': '2'}),
          ]).status,
          EpisodeLookupStatus.conflict,
        );
        expect(
          lookup(episode('a'), [], complete: false).status,
          EpisodeLookupStatus.uncertain,
        );
        expect(
          lookup(episode('a'), [], success: false).status,
          EpisodeLookupStatus.queryFailed,
        );
        expect(
          lookup(episode('a', scheme: null), [episode('b')]).source,
          isNull,
        );
        expect(
          lookup(episode('a'), [
            episode('b'),
            EpisodeSource(
              reference: ref('b', id: 'duplicate'),
              series: ref('b'),
              season: 1,
              episode: 2,
              isSpecial: false,
              numberingScheme: 'aired',
            ),
          ]).status,
          EpisodeLookupStatus.ambiguous,
        );
      },
    );
    test('combined episodes remain uncertain even with verified ordering', () {
      final parsed = EpisodeSource.fromEmby(
        ref('b', id: 'combined'),
        EmbyItem.fromJson({
          'Id': 'combined',
          'Type': 'Episode',
          'SeriesId': 'same',
          'ParentIndexNumber': 1,
          'IndexNumber': 2,
          'IndexNumberEnd': 3,
        }),
        numberingScheme: 'aired',
      );
      expect(parsed.hasCoordinates, isFalse);
      expect(
        lookup(episode('a'), [parsed]).status,
        EpisodeLookupStatus.uncertain,
      );
      expect(lookup(episode('a'), [parsed]).source, isNull);
    });

    test('Emby numbering alone is unknown until verified', () {
      final parsed = EpisodeSource.fromEmby(
        ref('a', id: 'ep'),
        const EmbyItem(
          id: 'ep',
          name: 'Episode',
          type: 'Episode',
          seriesId: 'same',
          parentIndexNumber: 1,
          indexNumber: 2,
        ),
      );
      expect(parsed.hasCoordinates, isFalse);
    });
  });
}
