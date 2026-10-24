import '../../auth/server_entry_coordinator.dart';

import 'package:rillight/media_server/media_server_client.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../auth/source_sessions.dart';
import '../../library/local_session_permit.dart';
import '../history/history_writer.dart';
import 'aggregation_query.dart';

class SourceComparison {
  const SourceComparison(this.source, this.decision);
  final QueryItem source;
  final MatchDecision decision;

  /// The original DTO holds known versions/streams. Missing fields stay null.
}

class _KnownSeasonEpisodes {
  const _KnownSeasonEpisodes({required this.available, required this.complete});

  final List<EpisodeSource> available;
  final bool complete;
}

class EpisodeComparison {
  const EpisodeComparison(
    this.target,
    this.status,
    this.lookup, {
    this.cursor = 0,
    this.total,
    this.item,
    this.detailLoading = false,
  });
  final SourceReference target;
  final SourceQueryStatus status;
  final EpisodeLookup lookup;
  final int cursor;
  final int? total;

  /// Detail DTO of the confirmed episode, carrying its versions and streams so
  /// the comparison can show them like a movie. Null while loading, or when
  /// the detail request failed; the confirmed lookup stays usable either way.
  final MediaItem? item;

  /// True while [item] is being read for a confirmed episode.
  final bool detailLoading;
}

/// Detail-owned query; never mutates or depends on global search state.
/// Provider and title lookups run independently in allowed libraries, so
/// localized titles cannot hide a provider-confirmed edition. Adapters without
/// provider lookup retain library discovery alongside the fast title query.
class SameSourceQueryController extends ChangeNotifier {
  SameSourceQueryController({
    required SourceSessionRegistry registry,
    required HistoryWriter history,
    Duration timeout = const Duration(seconds: 15),
  }) : query = AggregationQueryController(
         registry: registry,
         history: history,
         timeout: timeout,
       ) {
    query.addListener(_changed);
  }
  final AggregationQueryController query;
  QueryItem? _origin;
  OperationPermit? _originPermit;
  int _revision = 0;
  bool _disposed = false;
  final Map<SourceReference, EpisodeComparison> _episodes = {};
  final Map<SourceReference, int> _attempts = {};
  WorkIndex? _index;
  int _nextAttempt = 0;
  QueryItem? get origin => _originPermit?.isValid == true ? _origin : null;
  List<SourceQuerySnapshot> get sources => query.sources;
  bool get complete => sources.isEmpty || query.complete;
  bool get loading => sources.any(
    (source) =>
        source.status == SourceQueryStatus.loading ||
        source.status == SourceQueryStatus.idle,
  );
  WorkIndex _comparisonIndex() => _index ??= WorkIndex()
    ..upsert([
      if (origin != null) origin!.work,
      ...query.items.map((i) => i.work),
    ]);
  List<SourceComparison> get comparisons {
    final seed = origin;
    if (seed == null) return const [];
    final index = _comparisonIndex();
    final group = index.groupFor(seed.reference);
    return List.unmodifiable(
      query.items
          .where((i) => i.reference != seed.reference)
          .map((i) {
            final decision = compareWorks(seed.work, i.work);
            if (group?.contains(i.reference) == true) {
              return SourceComparison(
                i,
                const MatchDecision(
                  MatchKind.confirmed,
                  MatchReason.commonProvider,
                ),
              );
            }
            // A pairwise edge cannot bypass WorkIndex's group-wide conflicts.
            return SourceComparison(
              i,
              decision.confirmed
                  ? const MatchDecision(
                      MatchKind.candidate,
                      MatchReason.providerConflict,
                    )
                  : decision,
            );
          })
          .where((c) => c.decision.kind != MatchKind.unrelated),
    );
  }

  WorkGroup? _confirmedGroup(SourceReference target) {
    final seed = origin;
    if (seed == null) return null;
    final group = _comparisonIndex().groupFor(seed.reference);
    return group?.contains(target) == true &&
            query.items.any((i) => i.reference == target && i.item.isSeries)
        ? group
        : null;
  }

  void _revalidateEpisodes() {
    // Permanently retire attempts when their confirmation disappears, even if
    // the same references later merge again before an old HTTP reply arrives.
    final invalid = _attempts.keys
        .where((ref) => _confirmedGroup(ref) == null)
        .toList();
    for (final ref in invalid) {
      _attempts.remove(ref);
      _episodes.remove(ref);
    }
  }

  List<EpisodeComparison> get episodes {
    _revalidateEpisodes();
    return List.unmodifiable(_episodes.values);
  }

  Future<void> start({required QueryItem origin, required QueryScope scope}) {
    final permit = permitForAccount(
      query.registry,
      origin.reference.account,
      libraryId: origin.libraryId,
    );
    if (permit == null) throw StateError('Source access revoked');
    permit.requireValid();
    // Avoid replacing the origin's session when its service is also selected.
    query.useAccount(origin.reference.account, libraryId: origin.libraryId);
    _revision++;
    _origin = origin;
    _originPermit = permit;
    _index = null;
    _episodes.clear();
    _attempts.clear();
    return query.start(
      QueryScope(
        serverIds: scope.serverIds,
        libraries: scope.libraries,
        pageSize: scope.pageSize,
        types: {origin.item.type},
        sameWork: origin.work,
      ),
    );
  }

  Future<void> addEntry(ServerEntryTicket entry) => query.addEntry(entry);
  ServerEntryTicket? entryFor(String serverId) => query.entryFor(serverId);
  OperationPermit permitForItem(QueryItem item) =>
      query.permitFor(item.reference.account, libraryId: item.libraryId);

  // Keep the independent provider/title cursors together for the library's
  // user-facing actions; neither lane can consume the other's page offset.
  Future<void> loadMore(QuerySourceKey key) => Future.wait([
    for (final source in sources)
      if (source.key.serverId == key.serverId &&
          source.key.libraryId == key.libraryId &&
          !source.failed)
        query.loadMore(source.key),
  ]).then((_) {});

  Future<void> retry(QuerySourceKey key) {
    final related = sources
        .where(
          (source) =>
              source.key.serverId == key.serverId &&
              source.key.libraryId == key.libraryId,
        )
        .toList();
    final failed = related.any((source) => source.failed);
    return Future.wait([
      for (final source in related)
        if (!failed || source.failed) query.retry(source.key),
    ]).then((_) {});
  }

  /// Call for a confirmed series edition only. Unknown numbering is deliberately
  /// uncertain. A verified numbering scheme must come from explicit mapping,
  /// not an assumption based on IndexNumber. Repeating retries only this target.
  Future<void> lookupEpisode({
    required QueryItem target,
    required EpisodeSource episode,
    String? verifiedNumberingScheme,
  }) async {
    final seed = origin;
    if (seed == null ||
        episode.series != seed.reference.item ||
        episode.reference.account != seed.reference.account) {
      throw StateError('Episode does not belong to permitted origin');
    }
    final group = _confirmedGroup(target.reference);
    if (group == null ||
        target.item.type != 'Series' ||
        !query.items.any(
          (i) =>
              i.reference == target.reference &&
              i.libraryId == target.libraryId,
        )) {
      throw StateError('Confirmed allowed series required');
    }
    final revision = _revision;
    final attempt = ++_nextAttempt;
    _attempts[target.reference] = attempt;
    bool owns() =>
        !_disposed &&
        revision == _revision &&
        origin != null &&
        _attempts[target.reference] == attempt &&
        _confirmedGroup(target.reference) != null;
    _episodes[target.reference] = EpisodeComparison(
      target.reference,
      SourceQueryStatus.loading,
      const EpisodeLookup(EpisodeLookupStatus.uncertain),
    );
    notifyListeners();
    if (!owns()) return;
    OperationPermit? permit;
    try {
      permit = permitForItem(target);
      final wanted = {
        for (final entry in episode.providerIds.entries)
          if (reliableProviderId(entry.key, entry.value))
            entry.key: entry.value,
      };
      if (wanted.isNotEmpty) {
        final indexed = await permit
            .dispatch((client) async {
              if (client is! MediaProviderLookup) return null;
              final lookup = client as MediaProviderLookup;
              return lookup.queryProviderItems(
                parentId: target.reference.itemId,
                includeItemTypes: 'Episode',
                providerIds: wanted,
                limit: 8,
                startIndex: 0,
                fields: MediaServerClient.gridFields,
              );
            })
            .timeout(query.timeout);
        if (!owns() || !permit.isValid) return;
        if (indexed != null && indexed.items.isNotEmpty) {
          final lookup = locateEpisode(
            series: _confirmedGroup(target.reference)!,
            origin: episode,
            targetAccount: target.reference.account,
            available: indexed.items
                .where((item) => item.isEpisode)
                .map(
                  (item) => EpisodeSource.fromMediaItem(
                    SourceReference(
                      account: target.reference.account,
                      itemId: item.id,
                    ),
                    item,
                    numberingScheme: verifiedNumberingScheme,
                  ),
                ),
            complete: true,
          );
          if (lookup.status == EpisodeLookupStatus.confirmed ||
              lookup.status == EpisodeLookupStatus.conflict ||
              lookup.status == EpisodeLookupStatus.ambiguous) {
            _publishEpisode(target.reference, lookup, permit, owns);
            return;
          }
        }
      }
      // Provider miss: read only the already-known season. A full-series
      // episode scan must not delay this comparison row.
      final known = await _episodesInKnownSeason(
        permit: permit,
        target: target,
        episode: episode,
        verifiedNumberingScheme: verifiedNumberingScheme,
        owns: owns,
      );
      if (known == null || !owns()) return;
      final lookup = locateEpisode(
        series: _confirmedGroup(target.reference)!,
        origin: episode,
        targetAccount: target.reference.account,
        available: known.available,
        complete: known.complete,
      );
      _publishEpisode(target.reference, lookup, permit, owns);
      return;
    } catch (error) {
      if (!owns()) return;
      _episodes[target.reference] = EpisodeComparison(
        target.reference,
        classifyQueryFailure(error, expired: permit != null && !permit.isValid),
        const EpisodeLookup(EpisodeLookupStatus.queryFailed),
      );
    }
    if (owns()) notifyListeners();
  }

  /// Publishes a finished lookup. A confirmed episode is openable at once;
  /// its versions are read afterwards so the row never waits on them, and a
  /// failed detail request only leaves the row without version details.
  void _publishEpisode(
    SourceReference target,
    EpisodeLookup lookup,
    OperationPermit permit,
    bool Function() owns,
  ) {
    final found = lookup.source;
    final details =
        lookup.status == EpisodeLookupStatus.confirmed &&
        found != null &&
        permit.isValid;
    _episodes[target] = EpisodeComparison(
      target,
      SourceQueryStatus.available,
      lookup,
      detailLoading: details,
    );
    if (!owns()) return;
    notifyListeners();
    if (!details) return;
    void settle(MediaItem? item) {
      if (!owns()) return;
      final current = _episodes[target];
      if (current == null || !identical(current.lookup, lookup)) return;
      _episodes[target] = EpisodeComparison(
        target,
        current.status,
        lookup,
        cursor: current.cursor,
        total: current.total,
        item: item,
      );
      notifyListeners();
    }

    unawaited(
      permit
          .dispatch((client) => client.getItem(found.reference.itemId))
          .timeout(query.timeout)
          .then<void>(
            (item) => settle(
              permit.isValid &&
                      item.id == found.reference.itemId &&
                      item.isEpisode
                  ? item
                  : null,
            ),
            onError: (Object _) => settle(null),
          ),
    );
  }

  /// Episodes whose season index is already known on [episode]. Does not page
  /// the rest of the series. Null means this attempt no longer owns the lookup.
  Future<_KnownSeasonEpisodes?> _episodesInKnownSeason({
    required OperationPermit permit,
    required QueryItem target,
    required EpisodeSource episode,
    required String? verifiedNumberingScheme,
    required bool Function() owns,
  }) async {
    final seasonNumber = episode.season;
    if (seasonNumber == null) {
      return const _KnownSeasonEpisodes(available: [], complete: true);
    }
    final pageSize = query.scope!.pageSize;
    final seasons = <MediaItem>[];
    var cursor = 0;
    var uncertainRows = false;
    while (true) {
      if (!owns()) return null;
      final page = await permit
          .dispatch(
            (client) => client.queryItems(
              parentId: target.reference.itemId,
              includeItemTypes: 'Season',
              startIndex: cursor,
              limit: pageSize,
              fields: MediaServerClient.gridFields,
            ),
          )
          .timeout(query.timeout);
      if (!owns() || !permit.isValid) return null;
      cursor += page.items.length;
      uncertainRows |= page.items.any((item) => !item.isSeason);
      seasons.addAll(page.items.where((item) => item.isSeason));
      if (!page.hasMore(fetched: cursor, pageSize: pageSize)) break;
    }
    final known = [
      for (final season in seasons)
        if (season.indexNumber == seasonNumber) season,
    ];
    final unindexed = seasons.any((season) => season.indexNumber == null);
    if (known.isEmpty) {
      return _KnownSeasonEpisodes(
        available: const [],
        complete: !uncertainRows && !unindexed,
      );
    }
    final available = <EpisodeSource>[];
    for (final season in known) {
      var episodeCursor = 0;
      while (true) {
        if (!owns()) return null;
        final page = await permit
            .dispatch(
              (client) => client.queryItems(
                parentId: season.id,
                includeItemTypes: 'Episode',
                startIndex: episodeCursor,
                limit: pageSize,
                fields: MediaServerClient.gridFields,
              ),
            )
            .timeout(query.timeout);
        if (!owns() || !permit.isValid) return null;
        episodeCursor += page.items.length;
        uncertainRows |= page.items.any((item) => !item.isEpisode);
        available.addAll(
          page.items
              .where((item) => item.isEpisode)
              .map(
                (item) => EpisodeSource.fromMediaItem(
                  SourceReference(
                    account: target.reference.account,
                    itemId: item.id,
                  ),
                  item,
                  numberingScheme: verifiedNumberingScheme,
                ),
              ),
        );
        if (!page.hasMore(fetched: episodeCursor, pageSize: pageSize)) break;
      }
    }
    return _KnownSeasonEpisodes(
      available: available,
      complete: !uncertainRows && !unindexed,
    );
  }

  void _changed() {
    _index = null;
    if (origin == null) {
      _origin = null;
      _originPermit = null;
      _episodes.clear();
      _revision++;
    }
    _revalidateEpisodes();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    query.removeListener(_changed);
    query.dispose();
    _episodes.clear();
    super.dispose();
  }
}
