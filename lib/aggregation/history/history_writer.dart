import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../auth/region_access.dart';
import '../../auth/source_sessions.dart';
import '../../emby/emby_client.dart';
import '../../player/player_settings.dart';
import '../identity/media_identity.dart';
import 'history_models.dart';
import 'history_store.dart';

export 'history_models.dart';
export 'history_store.dart';

/// Opaque main-process token. IPC clients send its id and their own increasing
/// event sequence; only the main process resolves the id with sessionById.
class WatchSession {
  WatchSession._(this.id, this.source, this.work, this.libraryId, this.permit);
  final String id;
  final SourceReference source;
  final SourceReference work;
  final String libraryId;
  final OperationPermit permit;
  int _lastEvent = -1;
}

/// One authority for records AND scoped preferences; no PlayerSettings dual
/// write. Keep global PlayerSettings intact. Connect T5 main-process IPC here
/// and T4/T6 projections through records/resolveResume/resolvePreference.
class HistoryWriter implements Listenable {
  final _listeners = <VoidCallback>{};

  @override
  void addListener(VoidCallback listener) {
    if (!_closed) _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void _notifyCommitted() {
    for (final listener in _listeners.toList()) {
      if (_closed) break;
      if (!_listeners.contains(listener)) continue;
      try {
        listener();
      } catch (error, stack) {
        try {
          FlutterError.reportError(
            FlutterErrorDetails(exception: error, stack: stack),
          );
        } catch (_) {
          // An error reporter must not corrupt a committed authority write.
        }
      }
    }
  }

  HistoryWriter._(this.registry, this.store) {
    registry.access.addRevocationHook(_revokePrivate);
    registry.access.addCleanupHook(_lockCleanup);
    registry.addMembershipCleanup(_membershipCleanup);
  }
  static final Expando<bool> _owners = Expando<bool>();
  final SourceSessionRegistry registry;
  final HistoryStore store;
  final Map<String, WatchRecord> _records = {};
  final Map<String, SourcePreference> _preferences = {};
  final Map<int, int> _syncAttempts = {};
  final Set<String> _legacyConsumed = {};
  WatchSession? _active;
  int _order = 0;
  int _sessionCounter = 0;
  int _revision = 0;
  bool _closed = false;
  final Set<String> _revokedPreferenceKeys = {};
  Future<void> _tail = Future.value();

  static Future<HistoryWriter> open({
    required SourceSessionRegistry registry,
    required HistoryStore store,
  }) async {
    if (_owners[store] == true) throw StateError('History store already owned');
    _owners[store] = true;
    final writer = HistoryWriter._(registry, store);
    try {
      final json = await store.read();
      if (json != null) {
        if (json['version'] != 1) {
          throw const FormatException('Unknown history version');
        }
        writer._order = json['order'] as int;
        writer._revision = json['revision'] as int;
        writer._sessionCounter = json['sessions'] as int;
        for (final value in json['records'] as List) {
          final record = WatchRecord.fromJson(
            Map<String, dynamic>.from(value as Map),
          );
          writer._records[record.source.key] = record;
        }
        for (final value in json['preferences'] as List) {
          final pref = SourcePreference.fromJson(
            Map<String, dynamic>.from(value as Map),
          );
          writer._preferences[pref.owner.key] = pref;
        }
        writer._legacyConsumed.addAll(
          (json['legacyConsumed'] as List).cast<String>(),
        );
      }
      // Restart never resurrects private preferences from an interrupted lock.
      if (!registry.access.allows(AccessRegion.private)) {
        await writer._removeWhere(
          (account) => account.region == AccessRegion.private,
          records: false,
        );
      }
      return writer;
    } catch (_) {
      writer._detach();
      _owners[store] = false;
      await store.close();
      rethrow;
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    if (_closed) return Future.error(StateError('History writer closed'));
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Map<String, dynamic> _snapshot({
    Map<String, WatchRecord>? records,
    Map<String, SourcePreference>? preferences,
    Set<String>? consumed,
    int? order,
    int? sessions,
  }) => {
    'version': 1,
    'revision': _revision + 1,
    'order': order ?? _order,
    'sessions': sessions ?? _sessionCounter,
    'records': (records ?? _records).values.map((r) => r.toJson()).toList(),
    'preferences': (preferences ?? _preferences).values
        .map((p) => p.toJson())
        .toList(),
    'legacyConsumed': (consumed ?? _legacyConsumed).toList(),
  };

  Future<void> _commit({
    Map<String, WatchRecord>? records,
    Map<String, SourcePreference>? preferences,
    Set<String>? consumed,
    int? order,
    int? sessions,
  }) async {
    await store.replace(
      _snapshot(
        records: records,
        preferences: preferences,
        consumed: consumed,
        order: order,
        sessions: sessions,
      ),
    );
    _revision++;
    if (records != null) {
      _records
        ..clear()
        ..addAll(records);
    }
    if (preferences != null) {
      _preferences
        ..clear()
        ..addAll(preferences);
      _preferences.removeWhere(
        (key, _) => _revokedPreferenceKeys.contains(key),
      );
    }
    if (consumed != null) {
      _legacyConsumed
        ..clear()
        ..addAll(consumed);
    }
    if (order != null) _order = order;
    if (sessions != null) _sessionCounter = sessions;
    // Publish only committed authority facts. UI reads its allowed projection;
    // no snapshot of private records is broadcast into ordinary consumers.
    if (!_closed && (records != null || preferences != null)) {
      try {
        _notifyCommitted();
      } catch (_) {
        // Even a consumer's error reporter cannot turn a committed write into
        // a failed observation or consume/reorder the native event sequence.
      }
    }
  }

  Future<WatchSession> beginSession({
    required SourceReference source,
    required SourceReference work,
    required String libraryId,
  }) => _enqueue(() async {
    if (source.account != work.account ||
        source.mediaSourceId == null ||
        source.itemId.isEmpty ||
        work.itemId.isEmpty ||
        libraryId.isEmpty) {
      throw ArgumentError(
        'Actual version, source-specific work and library required',
      );
    }
    // 未勾选库的显式播放没有范围许可。会话仍有效时照常记这条观看，
    // 聚合历史列表会按范围把它滤掉。
    OperationPermit? scoped;
    try {
      scoped = registry.permit(source.account, libraryId: libraryId);
    } on StateError catch (error) {
      if (error.message != 'Source outside allowed scope') rethrow;
    }
    final permit =
        scoped ??
        registry.permit(
          source.account,
          libraryId: libraryId,
          sessionOnly: true,
        );
    permit.requireValid();
    await _commit(sessions: _sessionCounter + 1);
    permit.requireValid();
    return _active = WatchSession._(
      'watch-$_sessionCounter',
      source,
      work,
      libraryId,
      permit,
    );
  });

  WatchSession? sessionById(String id) =>
      _active?.id == id && _active!.permit.isValid ? _active : null;
  void endSession(WatchSession session) {
    if (identical(_active, session)) _active = null;
  }

  /// Submit only native/renderer-confirmed real playback, not Playing HTTP,
  /// preflight, resume snapshots or an unmounted first-frame notification.
  /// The per-session counter is consumed only after persistence succeeds.
  Future<WatchRecord?> observe({
    required WatchSession session,
    required int eventSequence,
    required int positionTicks,
    required bool actuallyPlaying,
    bool played = false,
    required WatchTimeline timeline,
    DateTime? observedAt,
  }) => _enqueue(() async {
    if (!identical(_active, session) ||
        eventSequence <= session._lastEvent ||
        !actuallyPlaying) {
      return null;
    }
    session.permit.requireValid();
    if (eventSequence < 0 ||
        positionTicks < 0 ||
        (timeline.durationTicks != null &&
            (timeline.durationTicks! < 0 ||
                positionTicks > timeline.durationTicks!))) {
      throw ArgumentError('Invalid observed timeline');
    }
    final record = WatchRecord(
      source: session.source,
      work: session.work,
      libraryId: session.libraryId,
      sessionId: session.id,
      eventSequence: eventSequence,
      localOrder: _order + 1,
      observedAt: observedAt ?? DateTime.now(),
      positionTicks: positionTicks,
      played: played,
      timeline: timeline,
    );
    await _commit(
      records: {..._records, record.source.key: record},
      order: record.localOrder,
    );
    _syncAttempts.removeWhere(
      (order, _) => !_records.values.any((r) => r.localOrder == order),
    );
    session._lastEvent = eventSequence;
    // A revocation during disk IO does not authorize dispatch or presentation.
    session.permit.requireValid();
    return record;
  });

  /// Report ONLY this persisted observation's actual source. Remote failures
  /// never remove/roll back history, and late acknowledgements cannot overwrite
  /// newer observations. The callback receives the independent permitted client.
  Future<void> synchronize(
    WatchRecord record,
    Future<void> Function(EmbyClient client, WatchRecord actual) report,
  ) async {
    final session = sessionById(record.sessionId);
    if (session == null || !identical(_records[record.source.key], record)) {
      return;
    }
    final attempt = (_syncAttempts[record.localOrder] ?? 0) + 1;
    _syncAttempts[record.localOrder] = attempt;
    var status = RemoteSyncStatus.succeeded;
    try {
      await session.permit.dispatch((client) => report(client, record));
    } catch (_) {
      status = RemoteSyncStatus.failed;
    }
    await _enqueue(() async {
      if (!session.permit.isValid ||
          _syncAttempts[record.localOrder] != attempt ||
          _records[record.source.key]?.localOrder != record.localOrder) {
        return;
      }
      await _commit(
        records: {
          ..._records,
          record.source.key: record.withRemoteStatus(status),
        },
      );
    });
  }

  bool _allows(SourceReference source, String libraryId, AccessRegion region) {
    if (source.account.region != region || libraryId.isEmpty) return false;
    try {
      return registry.permit(source.account, libraryId: libraryId).isValid;
    } on StateError {
      return false;
    }
  }

  List<WatchRecord> records(AccessRegion region) => List.unmodifiable(
    _records.values
        .where((r) => _allows(r.source, r.libraryId, region))
        .toList()
      ..sort((a, b) => b.localOrder.compareTo(a.localOrder)),
  );

  ResumeChoice resolveResume({
    required AccessRegion region,
    required WorkIndex index,
    required SourceReference anchor,
    Iterable<RemoteWatch> remote = const [],
  }) {
    if (anchor.account.region != region || !registry.access.allows(region)) {
      return const ResumeChoice(ResumeKind.empty);
    }
    final group = index.groupFor(anchor);
    if (group == null) return const ResumeChoice(ResumeKind.empty);
    final local = records(
      region,
    ).where((r) => identical(index.groupFor(r.work), group)).firstOrNull;
    if (local != null) return ResumeChoice(ResumeKind.local, local: local);
    final candidates = remote
        .where(
          (r) =>
              _allows(r.source, r.libraryId, region) &&
              r.work.account == r.source.account &&
              identical(index.groupFor(r.work), group),
        )
        .toList();
    if (candidates.isEmpty) return const ResumeChoice(ResumeKind.empty);
    if (candidates.length == 1) {
      return ResumeChoice(ResumeKind.remote, remote: candidates.single);
    }
    if (candidates.any((r) => !r.timeTrusted || r.playedAt == null)) {
      return ResumeChoice(
        ResumeKind.conflict,
        conflicts: List.unmodifiable(candidates),
      );
    }
    candidates.sort((a, b) => b.playedAt!.compareTo(a.playedAt!));
    final latest = candidates.first.playedAt;
    final tied = candidates.where((r) => r.playedAt == latest).toList();
    if (tied.length != 1) {
      return ResumeChoice(
        ResumeKind.conflict,
        conflicts: List.unmodifiable(candidates),
      );
    }
    return ResumeChoice(ResumeKind.remote, remote: candidates.first);
  }

  Future<void> savePreference(SourcePreference preference) => _enqueue(
    () async {
      if (preference.owner.account.region != preference.target.account.region) {
        throw ArgumentError('Preference cannot cross regions');
      }
      final ownerPermit = registry.permit(preference.owner.account);
      final permit = registry.permit(
        preference.target.account,
        libraryId: preference.libraryId,
      );
      ownerPermit.requireValid();
      permit.requireValid();
      if (preference.lineId != null &&
          !registry
              .project(preference.target.account.region)
              .firstWhere(
                (s) => s.id == preference.target.account.configuredServerId,
              )
              .lines
              .any((l) => l.id == preference.lineId)) {
        throw ArgumentError('Unknown preferred line');
      }
      await _commit(
        preferences: {..._preferences, preference.owner.key: preference},
      );
      if (!ownerPermit.isValid || !permit.isValid) {
        _preferences.remove(preference.owner.key);
        _revokedPreferenceKeys.add(preference.owner.key);
        throw StateError('Preference operation revoked');
      }
      _revokedPreferenceKeys.remove(preference.owner.key);
      _preferences[preference.owner.key] = preference;
    },
  );

  PreferenceFailure? _failure(SourcePreference pref, AccessRegion region) {
    if (!registry.access.allows(region)) return PreferenceFailure.regionLocked;
    if (pref.owner.account.region != region ||
        pref.target.account.region != region) {
      return PreferenceFailure.wrongRegion;
    }
    final server = registry
        .project(region)
        .where((s) => s.id == pref.target.account.configuredServerId)
        .firstOrNull;
    if (server == null) return PreferenceFailure.serverRemoved;
    if (!server.participates) return PreferenceFailure.notParticipating;
    if (!server.scopeKnown) return PreferenceFailure.unknownScope;
    if (!server.libraryIds.contains(pref.libraryId)) {
      return PreferenceFailure.libraryExcluded;
    }
    try {
      registry.permit(pref.owner.account).requireValid();
    } on StateError {
      return PreferenceFailure.accountUnavailable;
    }
    if (!_allows(pref.target, pref.libraryId, region)) {
      return PreferenceFailure.accountUnavailable;
    }
    if (pref.lineId != null && !server.lines.any((l) => l.id == pref.lineId)) {
      return PreferenceFailure.lineRemoved;
    }
    return null;
  }

  /// candidates MUST be freshly resolved, permitted concrete item versions.
  /// For nextEpisode, supply T2 locateEpisode results in episodeLookups for the
  /// intended next episode. Unconfirmed/missing/different items are excluded.
  /// Labels align a version, never the previous episode's mediaSourceId.
  PreferenceResolution resolvePreference({
    required SourceReference owner,
    required AccessRegion region,
    required Iterable<PreferenceCandidate> candidates,
    bool nextEpisode = false,
    Map<SourceAccount, EpisodeLookup> episodeLookups = const {},
  }) {
    bool confirmedEpisode(PreferenceCandidate candidate) {
      final lookup = episodeLookups[candidate.source.account];
      return lookup?.status == EpisodeLookupStatus.confirmed &&
          lookup?.source?.reference.item == candidate.source.item;
    }

    final allowed = List<PreferenceCandidate>.unmodifiable(
      candidates.where(
        (c) =>
            c.source.mediaSourceId != null &&
            (!nextEpisode || confirmedEpisode(c)) &&
            _allows(c.source, c.libraryId, region),
      ),
    );
    final pref =
        owner.account.region == region && registry.access.allows(region)
        ? _preferences[owner.key]
        : null;
    PreferenceFailure? failure = !registry.access.allows(region)
        ? PreferenceFailure.regionLocked
        : owner.account.region != region
        ? PreferenceFailure.wrongRegion
        : pref == null
        ? PreferenceFailure.notConfigured
        : _failure(pref, region);
    PreferenceCandidate? selected;
    if (failure == null && pref != null) {
      final matching = allowed
          .where(
            (c) => nextEpisode
                ? c.source.account == pref.target.account &&
                      pref.settings.mediaSourceName != null &&
                      c.versionName == pref.settings.mediaSourceName
                : c.source == pref.target,
          )
          .toList();
      if (matching.length == 1) {
        selected = matching.single;
      } else {
        failure = nextEpisode
            ? PreferenceFailure.versionUncertain
            : PreferenceFailure.targetMissing;
      }
    }
    return PreferenceResolution(
      preference: pref,
      selected: selected,
      failure: failure,
      allowedCandidates: allowed,
    );
  }

  /// Exact complete concrete-version references are required for attribution.
  /// A unique item alone is insufficient: normal resolution needs an exact
  /// target version. Multiple versions remain ambiguous, regardless of labels.
  /// inventoryComplete attests that the importer checked every configured
  /// account/region (including private); partial queries/locked views are false.
  /// Ambiguous ids remain unapplied. A persisted consumed id prevents an old
  /// PlayerSettings entry from reviving after migration, lock or restart.
  Future<PreferenceFailure?> migrateLegacy({
    required String seriesId,
    required PlayerSeriesPreference settings,
    required Iterable<PreferenceCandidate> candidates,
    required bool inventoryComplete,
  }) => _enqueue(() async {
    if (!inventoryComplete) return PreferenceFailure.ambiguousLegacy;
    final unique = {
      for (final c in candidates)
        if (c.source.itemId == seriesId) c.source.key: c,
    };
    if (unique.length != 1) return PreferenceFailure.ambiguousLegacy;
    if (_legacyConsumed.contains(seriesId)) {
      return PreferenceFailure.notConfigured;
    }
    final candidate = unique.values.single;
    if (candidate.source.mediaSourceId == null ||
        candidate.source.mediaSourceId!.trim().isEmpty) {
      return PreferenceFailure.ambiguousLegacy;
    }
    final permit = registry.permit(
      candidate.source.account,
      libraryId: candidate.libraryId,
    );
    permit.requireValid();
    final pref = SourcePreference(
      owner: candidate.source.item,
      target: candidate.source,
      libraryId: candidate.libraryId,
      settings: settings.portableIntent,
    );
    // Keep the verified version for this item, not for a new episode.
    // Track indices are discarded; nextEpisode resolution only uses explicit
    // language/version labels and a freshly confirmed episode reference.
    await _commit(
      preferences: {
        ..._preferences,
        if (!_preferences.containsKey(pref.owner.key)) pref.owner.key: pref,
      },
      consumed: {..._legacyConsumed, seriesId},
    );
    if (!permit.isValid) {
      _preferences.remove(pref.owner.key);
      _revokedPreferenceKeys.add(pref.owner.key);
      throw StateError('Legacy preference operation revoked');
    }
    return null;
  });

  void _revokePrivate() {
    if (_active?.source.account.region == AccessRegion.private) _active = null;
    for (final pref in _preferences.values) {
      if (pref.owner.account.region == AccessRegion.private ||
          pref.target.account.region == AccessRegion.private) {
        _revokedPreferenceKeys.add(pref.owner.key);
      }
    }
    _preferences.removeWhere((key, _) => _revokedPreferenceKeys.contains(key));
  }

  Future<void> _lockCleanup(RestrictedStopPermit _) =>
      _removeWhere((a) => a.region == AccessRegion.private, records: false);
  Future<void> _membershipCleanup(SourceAccount? _, String serverId) {
    if (_active?.source.account.configuredServerId == serverId ||
        _active?.work.account.configuredServerId == serverId) {
      _active = null;
    }
    for (final pref in _preferences.values) {
      if (pref.owner.account.configuredServerId == serverId ||
          pref.target.account.configuredServerId == serverId) {
        _revokedPreferenceKeys.add(pref.owner.key);
      }
    }
    _preferences.removeWhere((key, _) => _revokedPreferenceKeys.contains(key));
    return _removeWhere((a) => a.configuredServerId == serverId);
  }

  Future<void> _removeWhere(
    bool Function(SourceAccount) predicate, {
    bool records = true,
  }) => _enqueue(() async {
    final remainingRecords = Map<String, WatchRecord>.of(_records);
    if (records) {
      remainingRecords.removeWhere(
        (_, r) => predicate(r.source.account) || predicate(r.work.account),
      );
    }
    final remainingPreferences = Map<String, SourcePreference>.of(_preferences)
      ..removeWhere(
        (_, p) => predicate(p.owner.account) || predicate(p.target.account),
      );
    await _commit(records: remainingRecords, preferences: remainingPreferences);
  });

  void _detach() {
    registry.access.removeRevocationHook(_revokePrivate);
    registry.access.removeCleanupHook(_lockCleanup);
    registry.removeMembershipCleanup(_membershipCleanup);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _active = null;
    _detach();
    await _tail;
    await store.close();
    _owners[store] = false;
    _listeners.clear();
  }
}
