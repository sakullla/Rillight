import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../auth/source_sessions.dart';
import '../../emby/emby_client.dart';
import '../history/history_writer.dart';
import 'aggregation_query.dart';

class SourceComparison {
  const SourceComparison(this.source, this.decision);
  final QueryItem source;
  final MatchDecision decision;

  /// The original DTO holds known versions/streams. Missing fields stay null.
}

class EpisodeComparison {
  const EpisodeComparison(
    this.target,
    this.status,
    this.lookup, {
    this.cursor = 0,
    this.total,
  });
  final SourceReference target;
  final SourceQueryStatus status;
  final EpisodeLookup lookup;
  final int cursor;
  final int? total;
}

/// Detail-owned query; never mutates or depends on global search state.
/// Discovery walks allowed libraries (not only title search), so localized
/// titles cannot hide a provider-confirmed edition. Title-only is candidate.
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
  QueryItem? get origin => _originPermit?.isValid == true ? _origin : null;
  List<SourceQuerySnapshot> get sources => query.sources;
  bool get complete => query.complete;
  WorkIndex _comparisonIndex() => WorkIndex()
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

  List<EpisodeComparison> get episodes {
    final allowed = query.items.map((i) => i.reference).toSet();
    if (origin == null) return const [];
    return List.unmodifiable(
      _episodes.values.where((e) => allowed.contains(e.target)),
    );
  }

  Future<void> start({required QueryItem origin, required QueryScope scope}) {
    if (origin.reference.account.region != scope.region) {
      throw ArgumentError('Cross-region comparison rejected');
    }
    final permit = query.registry.permit(
      origin.reference.account,
      libraryId: origin.libraryId,
    );
    permit.requireValid();
    // Avoid replacing the origin's session when its service is also selected.
    query.useAccount(origin.reference.account, libraryId: origin.libraryId);
    _revision++;
    _origin = origin;
    _originPermit = permit;
    _episodes.clear();
    _attempts.clear();
    return query.start(
      QueryScope(
        region: scope.region,
        serverIds: scope.serverIds,
        libraries: scope.libraries,
        pageSize: scope.pageSize,
        types: {origin.item.type},
      ),
    );
  }

  Future<void> loadMore(QuerySourceKey key) => query.loadMore(key);
  Future<void> retry(QuerySourceKey key) => query.retry(key);

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
    final group = _comparisonIndex().groupFor(seed.reference);
    if (group == null ||
        !group.contains(target.reference) ||
        target.item.type != 'Series' ||
        !query.items.any(
          (i) =>
              i.reference == target.reference &&
              i.libraryId == target.libraryId,
        )) {
      throw StateError('Confirmed allowed series required');
    }
    final revision = _revision;
    final attempt = (_attempts[target.reference] ?? 0) + 1;
    _attempts[target.reference] = attempt;
    bool owns() =>
        !_disposed &&
        revision == _revision &&
        origin != null &&
        _attempts[target.reference] == attempt &&
        query.items.any((i) => i.reference == target.reference);
    _episodes[target.reference] = EpisodeComparison(
      target.reference,
      SourceQueryStatus.loading,
      const EpisodeLookup(EpisodeLookupStatus.uncertain),
    );
    notifyListeners();
    if (!owns()) return;
    OperationPermit? permit;
    var cursor = 0;
    int? total;
    final available = <EpisodeSource>[];
    var uncertainRows = false;
    try {
      permit = query.registry.permit(
        target.reference.account,
        libraryId: target.libraryId,
      );
      while (true) {
        if (!owns()) return;
        final page = await permit
            .dispatch(
              (client) => client.queryItems(
                parentId: target.reference.itemId,
                includeItemTypes: 'Episode',
                recursive: true,
                startIndex: cursor,
                limit: query.scope!.pageSize,
                fields: EmbyClient.itemFields,
              ),
            )
            .timeout(query.timeout);
        if (!owns() || !permit.isValid) return;
        cursor += page.items.length;
        total = page.totalRecordCount;
        // Unexpected or missing item type is unknown, not proof of a missing
        // target episode. Other incomplete coordinates are handled by T2.
        uncertainRows |= page.items.any((item) => !item.isEpisode);
        _episodes[target.reference] = EpisodeComparison(
          target.reference,
          SourceQueryStatus.loading,
          const EpisodeLookup(EpisodeLookupStatus.uncertain),
          cursor: cursor,
          total: total,
        );
        notifyListeners();
        available.addAll(
          page.items
              .where((i) => i.isEpisode)
              .map(
                (i) => EpisodeSource.fromEmby(
                  SourceReference(
                    account: target.reference.account,
                    itemId: i.id,
                  ),
                  i,
                  numberingScheme: verifiedNumberingScheme,
                ),
              ),
        );
        if (!page.hasMore(fetched: cursor, pageSize: query.scope!.pageSize)) {
          break;
        }
      }
      if (!owns()) return;
      final lookup = locateEpisode(
        series: group,
        origin: episode,
        targetAccount: target.reference.account,
        available: available,
        complete: !uncertainRows,
      );
      _episodes[target.reference] = EpisodeComparison(
        target.reference,
        SourceQueryStatus.available,
        lookup,
        cursor: cursor,
        total: total,
      );
    } catch (error) {
      if (!owns()) return;
      _episodes[target.reference] = EpisodeComparison(
        target.reference,
        classifyQueryFailure(error, expired: permit != null && !permit.isValid),
        const EpisodeLookup(EpisodeLookupStatus.queryFailed),
        cursor: cursor,
        total: total,
      );
    }
    if (owns()) notifyListeners();
  }

  void _changed() {
    if (origin == null) {
      _origin = null;
      _originPermit = null;
      _episodes.clear();
      _revision++;
    }
    final allowed = query.items.map((i) => i.reference).toSet();
    _episodes.removeWhere((ref, _) => !allowed.contains(ref));
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
