import '../../auth/server_entry_coordinator.dart';

import 'package:rillight/media_server/media_server_client.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../auth/source_sessions.dart';
import '../../library/local_session_permit.dart';
import '../../media_server/errors.dart';
import '../history/history_writer.dart';
import '../identity/media_identity.dart';

export '../identity/media_identity.dart';
export '../history/history_writer.dart' show WatchRecord, ResumeChoice;

enum QueryMode { browse, search, recent, continueWatching, nextUp }

enum SourceQueryStatus {
  idle,
  loading,
  available,
  empty,
  timeout,
  offline,
  needsLogin,
  forbidden,
  failed,
  revoked,
}

enum QuerySummary {
  emptyScope,
  loading,
  empty,
  available,
  partialFailure,
  allFailed,
}

/// Null serverIds means all currently accessible servers. An empty set
/// deliberately selects nothing. Library IDs are query filters, never authority.
class QueryScope {
  QueryScope({
    Set<String>? serverIds,
    Map<String, Set<String>> libraries = const {},
    this.mode = QueryMode.browse,
    this.keyword = '',
    Set<String>? types,
    Set<int> years = const {},
    Set<String> genres = const {},
    this.played,
    this.pageSize = 50,
    this.sortBy = 'SortName',
    this.descending = false,
    this.sameWork,
  }) : serverIds = serverIds == null ? null : Set.unmodifiable(serverIds),
       libraries = Map.unmodifiable(
         libraries.map((k, v) => MapEntry(k, Set<String>.unmodifiable(v))),
       ),
       types = Set.unmodifiable(
         types ??
             (mode == QueryMode.nextUp
                 ? const {'Episode'}
                 : mode == QueryMode.continueWatching
                 ? const {'Movie', 'Episode'}
                 : const {'Movie', 'Series'}),
       ),
       years = Set.unmodifiable(years),
       genres = Set.unmodifiable(genres) {
    if (pageSize <= 0) throw ArgumentError('Positive page size required');
    if (!const {'SortName', 'ProductionYear', 'DateCreated'}.contains(sortBy)) {
      throw ArgumentError('Unsupported loaded-set sort: $sortBy');
    }
  }
  final Set<String>? serverIds;
  final Map<String, Set<String>> libraries;
  final QueryMode mode;
  final String keyword;
  final Set<String> types;
  final Set<int> years;
  final Set<String> genres;
  final bool? played;
  final int pageSize;
  final String sortBy;
  final bool descending;

  /// Detail source lookup uses independent provider and title cursors. A
  /// localized title must not exclude an indexed provider match.
  final WorkSource? sameWork;
}

enum QuerySourceLane { catalog, title }

class QuerySourceKey {
  const QuerySourceKey(
    this.serverId,
    this.libraryId, {
    this.lane = QuerySourceLane.catalog,
  });
  final String serverId;
  final String libraryId;
  final QuerySourceLane lane;
  bool get isDiscovery => libraryId.isEmpty;
  @override
  bool operator ==(Object other) =>
      other is QuerySourceKey &&
      serverId == other.serverId &&
      libraryId == other.libraryId &&
      lane == other.lane;
  @override
  int get hashCode => Object.hash(serverId, libraryId, lane);
}

class SourceQueryState {
  SourceQueryState(this.key);
  final QuerySourceKey key;
  bool get isDiscovery => key.isDiscovery;
  SourceQueryStatus status = SourceQueryStatus.idle;
  int cursor = 0;
  int? total;
  bool hasMore = true;
  DateTime? checkedAt;
  OperationPermit? permit;
  int attempt = 0;
  final Map<SourceReference, QueryItem> items = {};
  SourceQuerySnapshot snapshot() =>
      SourceQuerySnapshot(key, status, cursor, total, hasMore, checkedAt);
}

class SourceQuerySnapshot {
  const SourceQuerySnapshot(
    this.key,
    this.status,
    this.cursor,
    this.total,
    this.hasMore,
    this.checkedAt,
  );
  final QuerySourceKey key;
  final SourceQueryStatus status;
  final int cursor;

  /// Source row total, not a deduplicated work count. Null stays unknown.
  final int? total;
  final bool hasMore;
  final DateTime? checkedAt;
  bool get failed => const {
    SourceQueryStatus.timeout,
    SourceQueryStatus.offline,
    SourceQueryStatus.needsLogin,
    SourceQueryStatus.forbidden,
    SourceQueryStatus.failed,
    SourceQueryStatus.revoked,
  }.contains(status);
}

/// Carries the exact account/item and library for subsequent permit acquisition.
/// DTO mediaSources/mediaStreams retain null unknown facts; no quality ranking.
class QueryItem {
  const QueryItem(this.reference, this.libraryId, this.item);
  final SourceReference reference;
  final String libraryId;
  final MediaItem item;
  WorkSource get work => WorkSource.fromMediaItem(reference, item);
}

/// Shared desktop/phone/TV browse/search controller. No timer or background
/// probing. Each page is dispatched and received through a frozen T1 permit.
class AggregationQueryController extends ChangeNotifier {
  AggregationQueryController({
    required this.registry,
    required this.history,
    this.timeout = const Duration(seconds: 15),
  }) {
    registry.access.addRevocationHook(_revoked);
    registry.addMembershipCleanup(_membership);
  }
  final SourceSessionRegistry registry;
  final HistoryWriter history;
  final Duration timeout;
  QueryScope? _scope;
  QueryScope? get scope => _scope;
  int _revision = 0;
  bool _disposed = false;
  final Map<QuerySourceKey, SourceQueryState> _states = {};
  final Map<String, SourceAccount> _accounts = {};
  final Map<String, Future<SourceAccount>> _authenticating = {};
  final WorkIndex _index = WorkIndex();
  bool _indexDirty = false;
  List<WorkGroup>? _sortedWorks;

  /// Source-based scroll anchor survives reliable group merges. UI resolves
  /// it with resolveAnchor after loading more; revoked sources clear it.
  SourceReference? anchor;
  final Map<String, ServerEntryTicket> _entries = {};
  bool _allows(String id) =>
      registry.access.allows(id) ||
      (_entries[id]?.authorizes(registry.access, id) ?? false);
  OperationPermit permitFor(SourceAccount account, {String? libraryId}) =>
      registry.permit(
        account,
        libraryId: libraryId,
        entry: _entries[account.configuredServerId],
      );
  ServerEntryTicket? entryFor(String serverId) => _entries[serverId];
  Future<void> addEntry(ServerEntryTicket entry) async {
    entry.requireValid();
    final scope = _scope;
    if (_disposed ||
        scope == null ||
        (scope.serverIds != null &&
            !scope.serverIds!.contains(entry.serverId))) {
      entry.cancel();
      throw StateError('Comparison scope changed');
    }
    _entries[entry.serverId]?.cancel();
    _entries[entry.serverId] = entry;
    final discovery = SourceQueryState(QuerySourceKey(entry.serverId, ''));
    _states[discovery.key] = discovery;
    await _discover(discovery);
  }

  Future<void> retryServer(String serverId) {
    _sanitize();
    return Future.wait(
      _states.values
          .where((s) => s.key.serverId == serverId && s.snapshot().failed)
          .map((s) => retry(s.key)),
    ).then((_) {});
  }

  Future<void> loadMoreServer(String serverId) {
    _sanitize();
    return Future.wait(
      _states.values
          .where(
            (s) =>
                s.key.serverId == serverId && s.hasMore && !s.snapshot().failed,
          )
          .map((s) => loadMore(s.key)),
    ).then((_) {});
  }

  bool _selected(QuerySourceKey key) {
    final scope = _scope;
    if (scope == null || !_allows(key.serverId)) return false;
    return registry.project().any(
      (s) =>
          s.id == key.serverId &&
          (scope.serverIds == null || scope.serverIds!.contains(s.id)) &&
          (key.isDiscovery ||
              !scope.libraries.containsKey(s.id) ||
              scope.libraries[s.id]!.contains(key.libraryId)),
    );
  }

  void _sanitize() {
    final before = _states.length;
    _states.removeWhere((key, state) => !_selected(key));
    if (_states.length != before) _indexDirty = true;
    for (final state in _states.values) {
      if (state.permit != null && !state.permit!.isValid) {
        if (state.items.isNotEmpty) _indexDirty = true;
        state.items.clear();
        state.total = null;
        state.hasMore = true;
        if (state.status != SourceQueryStatus.needsLogin) {
          state.status = SourceQueryStatus.revoked;
        }
      }
    }
    if (_indexDirty) _rebuild();
  }

  void _rebuild() {
    final items = _states.values.expand((s) => s.items.values).toList();
    final refs = items.map((i) => i.reference).toSet();
    _index.removeWhere((r) => !refs.contains(r));
    _index.upsert(items.map((i) => i.work));
    _indexDirty = false;
    _sortedWorks = null;
    if (anchor != null && _index.groupFor(anchor!) == null) anchor = null;
  }

  List<SourceQuerySnapshot> get sources {
    _sanitize();
    return List.unmodifiable(_states.values.map((s) => s.snapshot()));
  }

  List<QueryItem> get items {
    _sanitize();
    final unique = <SourceReference, QueryItem>{};
    for (final state in _states.values) {
      unique.addAll(state.items);
    }
    return List.unmodifiable(unique.values);
  }

  List<WorkGroup> get works {
    _sanitize();
    final cached = _sortedWorks;
    if (cached != null) return cached;
    final groups = _index.groups.toList();
    final facts = {for (final s in _states.values) ...s.items};
    final scope = _scope;
    final byDate =
        scope?.mode == QueryMode.recent || scope?.sortBy == 'DateCreated';
    final dates = <WorkGroup, int>{
      if (byDate)
        for (final group in groups)
          group:
              group.sources
                  .map((s) => facts[s.reference]?.item.dateCreated)
                  .whereType<DateTime>()
                  .fold<DateTime?>(
                    null,
                    (a, b) => a == null || b.isAfter(a) ? b : a,
                  )
                  ?.millisecondsSinceEpoch ??
              -1,
    };
    final titles = <WorkGroup, String>{
      if (!byDate && scope?.sortBy != 'ProductionYear')
        for (final group in groups)
          group: group.sources.first.title.toLowerCase(),
    };
    groups.sort((a, b) {
      int order;
      if (byDate) {
        order = dates[a]!.compareTo(dates[b]!);
      } else if (scope?.sortBy == 'ProductionYear') {
        order = (a.sources.first.year ?? -1).compareTo(
          b.sources.first.year ?? -1,
        );
      } else {
        order = titles[a]!.compareTo(titles[b]!);
      }
      if (scope?.descending == true || scope?.mode == QueryMode.recent) {
        order = -order;
      }
      return order == 0 ? a.key.compareTo(b.key) : order;
    });
    return _sortedWorks = List.unmodifiable(groups);
  }

  WorkGroup? resolveAnchor(SourceReference reference) {
    _sanitize();
    return _index.groupFor(reference);
  }

  /// Local order is T3's confirmed event order, not max playback position.
  List<WatchRecord> get localContinueWatching {
    final scope = _scope;
    if (scope == null) return const [];
    return List.unmodifiable(
      history.records().where(
        (r) =>
            !r.played &&
            _selected(
              QuerySourceKey(r.source.account.configuredServerId, r.libraryId),
            ),
      ),
    );
  }

  ResumeChoice resolveResume(
    SourceReference reference, {
    Iterable<RemoteWatch> remote = const [],
  }) {
    _sanitize();
    return history.resolveResume(
      index: _index,
      anchor: reference,
      remote: remote.where(
        (r) => _selected(
          QuerySourceKey(r.source.account.configuredServerId, r.libraryId),
        ),
      ),
    );
  }

  bool get complete =>
      sources.isNotEmpty &&
      sources.every(
        (s) =>
            !s.failed &&
            s.status != SourceQueryStatus.loading &&
            s.status != SourceQueryStatus.idle &&
            !s.hasMore,
      );

  /// Even with known per-source totals, merged work totals cannot be inferred.
  int? get totalWorks => complete ? works.length : null;
  bool get loadedOnlySort => !complete;
  QuerySummary get summary {
    final states = sources;
    if (states.isEmpty) return QuerySummary.emptyScope;
    final failed = states.where((s) => s.failed).length;
    if (failed == states.length) return QuerySummary.allFailed;
    if (failed > 0) return QuerySummary.partialFailure;
    if (items.isNotEmpty) return QuerySummary.available;
    if (states.any(
      (s) =>
          s.status == SourceQueryStatus.loading ||
          s.status == SourceQueryStatus.idle,
    )) {
      return QuerySummary.loading;
    }
    return QuerySummary.empty;
  }

  /// Resets results, counts, errors and anchor synchronously before first await.
  Future<void> start(QueryScope scope) async {
    _revision++;
    _scope = scope;
    anchor = null;
    _states.clear();
    _authenticating.clear();
    _index.removeWhere((_) => true);
    _indexDirty = false;
    _sortedWorks = null;
    final revision = _revision;
    final targets = registry
        .project()
        .where(
          (server) =>
              _allows(server.id) &&
              (scope.serverIds == null ||
                  scope.serverIds!.contains(server.id)) &&
              !(scope.mode == QueryMode.search && scope.keyword.trim().isEmpty),
        )
        .toList();
    for (final server in targets) {
      final key = QuerySourceKey(server.id, '');
      _states[key] = SourceQueryState(key)..status = SourceQueryStatus.loading;
    }
    notifyListeners();
    if (_disposed || revision != _revision) return;
    final discoveries = _states.values.toList();
    await Future.wait(discoveries.map(_discover));
  }

  Future<void> _discover(SourceQueryState discovery) async {
    final revision = _revision;
    final attempt = ++discovery.attempt;
    final scope = _scope!;
    final serverId = discovery.key.serverId;
    discovery.status = SourceQueryStatus.loading;
    discovery.hasMore = false;
    notifyListeners();
    bool current() => _owns(discovery, revision, attempt);
    try {
      if (!current()) return;
      final session =
          await (_entries[serverId] == null
                  ? registry.ensureSession(serverId)
                  : registry.prepareEntrySession(serverId))
              .timeout(timeout);
      if (!current()) return;
      final permit = permitFor(session.account);
      discovery.permit = permit;
      final views = await permit
          .dispatch((client) => client.getViews())
          .timeout(timeout);
      if (!current() || !permit.isValid) return;
      _states.remove(discovery.key);
      final states = <SourceQueryState>[];
      for (final view in views) {
        if (view.id.isEmpty ||
            (scope.libraries.containsKey(serverId) &&
                !scope.libraries[serverId]!.contains(view.id))) {
          continue;
        }
        final work = scope.sameWork;
        final lanes = [
          if (work == null ||
              work.reliableProviderIds.isNotEmpty ||
              work.title.trim().isEmpty)
            QuerySourceLane.catalog,
          if (work != null && work.title.trim().isNotEmpty)
            QuerySourceLane.title,
        ];
        for (final lane in lanes) {
          final key = QuerySourceKey(serverId, view.id, lane: lane);
          final state = SourceQueryState(key);
          _states[key] = state;
          states.add(state);
        }
      }
      notifyListeners();
      if (_disposed || revision != _revision) return;
      await Future.wait(states.map(_load));
    } catch (error) {
      if (!current()) return;
      discovery.status = classifyQueryFailure(error);
      notifyListeners();
    }
  }

  /// Reuse an already-authorized independent registry session (for detail
  /// opened from a query item). This does not attach a global auth client.
  void useAccount(SourceAccount account, {required String libraryId}) {
    final permit = permitForAccount(registry, account, libraryId: libraryId);
    if (permit == null || !permit.isValid) {
      throw StateError('Source access revoked');
    }
    _accounts[account.configuredServerId] = account;
  }

  Future<SourceAccount> _account(String id, String library) async {
    final cached = _accounts[id];
    if (cached != null) {
      try {
        permitFor(cached, libraryId: library).requireValid();
        return cached;
      } on StateError {
        _accounts.remove(id);
      }
    }
    final pending = _authenticating[id];
    if (pending != null) return pending;
    final future = _entries[id] == null
        ? registry.acquireAccount(id, libraryId: library)
        : registry.prepareEntrySession(id).then((session) => session.account);
    _authenticating[id] = future;
    try {
      final account = await future;
      _accounts[id] = account;
      return account;
    } finally {
      if (identical(_authenticating[id], future)) _authenticating.remove(id);
    }
  }

  Future<void> loadMore(QuerySourceKey key) async {
    _sanitize();
    final state = _states[key];
    if (state == null ||
        state.isDiscovery ||
        !state.hasMore ||
        state.status == SourceQueryStatus.loading) {
      return;
    }
    await _load(state);
  }

  Future<void> retry(QuerySourceKey key) async {
    _sanitize();
    final state = _states[key];
    if (state == null || state.status == SourceQueryStatus.loading) return;
    if (state.isDiscovery) {
      await _discover(state);
      return;
    }
    if (state.permit?.isValid == false) {
      state.cursor = 0;
      state.items.clear();
      _indexDirty = true;
      state.total = null;
      state.permit = null;
    }
    await _load(state);
  }

  bool _owns(SourceQueryState state, int revision, int attempt) =>
      !_disposed &&
      revision == _revision &&
      identical(_states[state.key], state) &&
      state.attempt == attempt &&
      _selected(state.key);
  Future<void> _load(SourceQueryState state) async {
    if (state.isDiscovery) throw StateError('Discovery is not a media library');
    final revision = _revision;
    final attempt = ++state.attempt;
    final scope = _scope!;
    state.status = SourceQueryStatus.loading;
    notifyListeners();
    if (!_owns(state, revision, attempt)) return;
    OperationPermit? permit;
    try {
      final account = await _account(
        state.key.serverId,
        state.key.libraryId,
      ).timeout(timeout);
      if (!_owns(state, revision, attempt)) return;
      permit = permitFor(account, libraryId: state.key.libraryId);
      state.permit = permit;
      final page = await permit
          .dispatch(
            (client) =>
                scope.sameWork != null &&
                    state.key.lane == QuerySourceLane.catalog &&
                    scope.sameWork!.reliableProviderIds.isNotEmpty &&
                    client is MediaProviderLookup
                ? (client as MediaProviderLookup).queryProviderItems(
                    parentId: state.key.libraryId,
                    includeItemTypes: scope.types.join(','),
                    providerIds: scope.sameWork!.reliableProviderIds,
                    limit: scope.pageSize,
                    startIndex: state.cursor,
                  )
                : scope.mode == QueryMode.nextUp
                ? client.queryNextUp(
                    parentId: state.key.libraryId,
                    limit: scope.pageSize,
                    startIndex: state.cursor,
                    fields: MediaServerClient.itemFields,
                  )
                : client.queryItems(
                    parentId: state.key.libraryId,
                    recursive: true,
                    searchTerm: state.key.lane == QuerySourceLane.title
                        ? scope.sameWork!.title.trim()
                        : scope.mode == QueryMode.search
                        ? scope.keyword.trim()
                        : null,
                    includeItemTypes: scope.types.join(','),
                    limit: scope.pageSize,
                    startIndex: state.cursor,
                    sortBy: scope.mode == QueryMode.recent
                        ? 'DateCreated'
                        : scope.sortBy,
                    sortOrder:
                        scope.descending || scope.mode == QueryMode.recent
                        ? 'Descending'
                        : 'Ascending',
                    years: scope.years.toList(),
                    genres: scope.genres.toList(),
                    filters: [
                      if (scope.mode == QueryMode.continueWatching)
                        'IsResumable',
                      if (scope.played != null)
                        scope.played! ? 'IsPlayed' : 'IsUnplayed',
                    ],
                    fields: MediaServerClient.itemFields,
                  ),
          )
          .timeout(timeout);
      if (!_owns(state, revision, attempt) || !permit.isValid) return;
      // Crop each source before WorkIndex sees it. A filter on one edition
      // cannot accidentally include a different edition via merged metadata.
      // Validate the entire accepted page before publishing any rows or cursor.
      // Identity decoding can reject ambiguous provider aliases; such failure
      // belongs to this source attempt, never to global getters or siblings.
      final accepted = <SourceReference, QueryItem>{};
      for (final item in page.items) {
        if (scope.types.isNotEmpty && !scope.types.contains(item.type)) {
          continue;
        }
        if (scope.years.isNotEmpty &&
            !scope.years.contains(item.productionYear)) {
          continue;
        }
        if (scope.genres.isNotEmpty &&
            !scope.genres.every(item.genres.contains)) {
          continue;
        }
        if (scope.played != null && item.userData.played != scope.played) {
          continue;
        }
        final ref = SourceReference(account: account, itemId: item.id);
        final result = QueryItem(ref, state.key.libraryId, item);
        result
            .work; // Fail closed; do not invent an identity for malformed DTOs.
        accepted[ref] = result;
      }
      state.items.addAll(accepted);
      _indexDirty = true;
      state.cursor += page.items.length;
      state.total = page.totalRecordCount;
      state.hasMore = page.hasMore(
        fetched: state.cursor,
        pageSize: scope.pageSize,
      );
      state.status = state.items.isEmpty
          ? SourceQueryStatus.empty
          : SourceQueryStatus.available;
      state.checkedAt = DateTime.now();
    } catch (error) {
      if (!_owns(state, revision, attempt)) return;
      state.status = classifyQueryFailure(
        error,
        expired: permit != null && !permit.isValid,
      );
      state.checkedAt = DateTime.now();
    }
    if (_owns(state, revision, attempt)) {
      _sanitize();
      notifyListeners();
    }
  }

  void _revoked() {
    _states.removeWhere((key, _) => !_allows(key.serverId));
    _accounts.removeWhere((id, _) => !_allows(id));
    _authenticating.removeWhere((id, _) => !_allows(id));
    if (anchor != null && !_allows(anchor!.account.configuredServerId)) {
      anchor = null;
    }
    _rebuild();
    if (!_disposed) notifyListeners();
  }

  Future<void> _membership(SourceAccount? account, String id) async {
    _states.removeWhere((k, _) => k.serverId == id);
    _accounts.remove(id);
    _authenticating.remove(id);
    _rebuild();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final entry in _entries.values) {
      entry.cancel();
    }
    _entries.clear();
    _revision++;
    registry.access.removeRevocationHook(_revoked);
    registry.removeMembershipCleanup(_membership);
    _states.clear();
    _accounts.clear();
    _authenticating.clear();
    _index.removeWhere((_) => true);
    _indexDirty = false;
    _sortedWorks = null;
    super.dispose();
  }
}

SourceQueryStatus classifyQueryFailure(Object error, {bool expired = false}) {
  if (expired) return SourceQueryStatus.needsLogin;
  if (error is TimeoutException) return SourceQueryStatus.timeout;
  if (error is MediaServerException) {
    if (error.statusCode == 403) return SourceQueryStatus.forbidden;
    return switch (error.kind) {
      MediaServerFailureKind.sessionExpired ||
      MediaServerFailureKind.invalidCredentials => SourceQueryStatus.needsLogin,
      MediaServerFailureKind.timeout => SourceQueryStatus.timeout,
      MediaServerFailureKind.unreachable ||
      MediaServerFailureKind.certificate => SourceQueryStatus.offline,
      _ => SourceQueryStatus.failed,
    };
  }
  if (error is StateError &&
      error.message.toString().contains('Login required')) {
    return SourceQueryStatus.needsLogin;
  }
  return SourceQueryStatus.failed;
}
