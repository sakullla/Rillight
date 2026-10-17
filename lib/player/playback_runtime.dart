import '../auth/server_entry_coordinator.dart';
import '../auth/server_list_store.dart';

import 'package:rillight/player/playback_persistence.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/errors.dart';

import 'dart:io';
import 'dart:convert';

import 'player_settings.dart';
import 'playback_recovery_coordinator.dart';
import '../media_server/capabilities.dart';
import '../media_server/server_address.dart';

import 'package:path_provider/path_provider.dart';

import '../auth/auth_controller.dart';
import '../auth/source_sessions.dart';
import '../aggregation/history/history_writer.dart';
import '../aggregation/identity/media_identity.dart';
import 'player_window_host.dart';
import '../media_server/playback.dart';

/// A resolved origin is a lease, not merely a value reference or auth.client.
class PlaybackOrigin {
  const PlaybackOrigin({
    required this.source,
    required this.work,
    required this.libraryId,
    required this.permit,
    required this.client,
    this.resolvedItem,
  });
  final SourceReference source;
  final SourceReference work;
  final String libraryId;
  final OperationPermit permit;
  final MediaServerClient client;

  /// Fresh metadata obtained while verifying membership. Only an immediate
  /// launch may reuse it; retained switch/recovery origins must refresh.
  final MediaItem? resolvedItem;
}

/// Created only by the application bootstrap, never by the player helper.
/// All embedded players and desktop IPC share this one history owner.
class PlaybackRuntime {
  PlaybackRuntime({required this.auth, required this.history}) {
    auth.playbackLineSelection = _selectPlaybackLine;
  }
  final AuthController auth;
  final HistoryWriter history;
  SourceSessionRegistry get registry => auth.sources;

  // Navigator page keys bind a mounted route instance, not decoded intent.
  // Imperative routes retain their page key across extra-codec refreshes.
  final Map<Object, PlaybackOrigin? Function()> _mountedPlayers = {};
  final Map<
    Object,
    ({
      String? Function() server,
      Future<void> Function(LineSelection, void Function()) select,
    })
  >
  _linePlayers = {};

  void registerLinePlayer(
    Object key,
    String? Function() server,
    Future<void> Function(LineSelection, void Function()) select,
  ) => _linePlayers[key] = (server: server, select: select);

  void unregisterLinePlayer(Object key) => _linePlayers.remove(key);

  Future<void> _selectPlaybackLine(
    String id,
    LineSelection selection,
    void Function() guard,
  ) async {
    for (final player in _linePlayers.values.toList().reversed) {
      if (player.server() == id) {
        await player.select(selection, guard);
        return;
      }
    }
    await auth.selectLine(id, selection, guard: guard);
  }

  Future<void> commitLine(
    PlaybackOrigin target,
    String lineId,
    LineSelection selection,
    void Function() guard,
  ) async {
    await registry.commitPlaybackLine(
      permit: target.permit,
      client: target.client,
      lineId: lineId,
      selection: selection,
      guard: guard,
    );
    auth.publishPlaybackConnection(
      target.source.account.configuredServerId,
      target.client,
    );
  }

  /// Verified item→library memberships. Proving membership walks ancestors
  /// serially (up to 32 GETs); re-opens of the same item must not pay that
  /// again while the proof is fresh. Library moves are rare; a short TTL
  /// bounds staleness.
  static const _membershipProofTtl = Duration(minutes: 10);
  final _membershipProofs = <String, DateTime>{};

  void mountPlayer(Object request, PlaybackOrigin? Function() origin) =>
      _mountedPlayers[request] = origin;

  void unmountPlayer(Object request) => _mountedPlayers.remove(request);

  void _rememberMembership(String key) {
    final now = DateTime.now();
    _membershipProofs
      ..removeWhere((_, at) => now.difference(at) >= _membershipProofTtl)
      ..[key] = now;
    while (_membershipProofs.length > 256) {
      _membershipProofs.remove(_membershipProofs.keys.first);
    }
  }

  bool hasMountedPlayer(Object request) => _mountedPlayers.containsKey(request);

  bool hasPlaybackFor(String serverId) => _mountedPlayers.values.any((read) {
    final origin = read();
    return origin?.source.account.configuredServerId == serverId &&
        origin?.permit.isValid == true;
  });

  PlaybackOrigin? mountedPlayerOrigin(Object request) =>
      _mountedPlayers[request]?.call();

  static Future<PlaybackRuntime> production(
    AuthController auth, {
    Directory? directory,
  }) async {
    final validation =
        Platform.environment['RILLIGHT_VALIDATION_DIRECTORY'] ??
        Platform.environment['RILLIGHT_VALIDATION_DATA_DIR'];
    if (validation != null &&
        (validation.isEmpty || !Directory(validation).isAbsolute)) {
      throw ArgumentError('Validation directory must be absolute');
    }
    final root =
        directory?.absolute.path ??
        validation ??
        '${(await getApplicationSupportDirectory()).path}/rillight';
    final file = File('$root/watch-history.json');
    final store = await FileHistoryStore.open(file);
    try {
      return PlaybackRuntime(
        auth: auth,
        history: await HistoryWriter.open(registry: auth.sources, store: store),
      );
    } catch (_) {
      await store.close();
      throw await FileHistoryStore.recoveryFailure(file);
    }
  }

  Future<ServerEntryTicket?> prepareSourceEntry(
    String serverId, {
    Future<String?> Function(SavedServer server)? requestPassword,
  }) => auth.serverEntry.prepareEntry(
    server: registry.server(serverId),
    requestPassword: () async => requestPassword == null
        ? null
        : await requestPassword(registry.server(serverId)),
    connect: (guard) => auth.prepareServerEntry(serverId, guard: guard),
  );

  Future<(SourceAccount, OperationPermit)> _playbackPermit(
    SourceReference source,
    String library, {
    ServerEntryTicket? entry,
  }) async {
    final account = entry != null
        ? (await registry.prepareEntrySession(
            source.account.configuredServerId,
          )).account
        : await registry.acquireAccount(
            source.account.configuredServerId,
            libraryId: library,
          );
    if (account != source.account) {
      throw StateError('Playback account changed');
    }
    return (
      account,
      registry.permit(account, libraryId: library, entry: entry),
    );
  }

  Future<PlaybackOrigin> resolve(
    PlayerOpenRequest request, {
    ServerEntryTicket? entry,
    PlaybackOrigin? connection,
  }) async {
    SourceReference? source = request.source;
    String? library = request.libraryId;
    if (entry != null &&
        (source == null ||
            !entry.authorizes(
              registry.access,
              source.account.configuredServerId,
            ) ||
            request.accessGeneration != entry.generation)) {
      throw StateError('Playback entry does not authorize this request');
    }
    if (source == null) {
      final selected = auth.session;
      if (selected == null) throw StateError('No selected source');
      if (registry.access.isProtected(selected.server.id) &&
          request.accessGeneration !=
              registry.access.generation(selected.server.id)) {
        throw StateError('Private playback route generation was revoked');
      }
      // The selected server's login is independent of aggregation filters.
      final account = (await registry.ensureSession(selected.server.id))
          .account;
      if (!identical(auth.session, selected) ||
          account.userId != selected.userId) {
        throw StateError('Playback account changed');
      }
      final permit = registry.permit(account);
      var item = await permit.dispatch(
        (c) => (connection?.client ?? c).getItem(request.itemId),
      );
      if (item.id != request.itemId) throw StateError('Source item mismatch');
      library = item.hierarchyParentId ?? item.id;
      source = SourceReference(
        account: account,
        itemId: request.itemId,
        mediaSourceId: request.mediaSourceId,
      );
    }
    if (source.itemId != request.itemId || library == null || library.isEmpty) {
      throw ArgumentError('Source and library must belong to playback item');
    }
    // Reject old decoded private intent before authentication/acquisition IO.
    if (entry == null &&
        registry.access.isProtected(source.account.configuredServerId) &&
        request.accessGeneration !=
            registry.access.generation(source.account.configuredServerId)) {
      throw StateError('Private playback route generation was revoked');
    }
    final (account, permit) = await _playbackPermit(
      source,
      library,
      entry: entry,
    );
    if (connection != null && connection.source.account != account) {
      throw StateError('Playback connection account mismatch');
    }
    // A decoded route is still only a value reference. Unlocking must not
    // reacquire the authority of a pre-lock private playback intent.
    if (registry.access.isProtected(account.configuredServerId) &&
        request.accessGeneration != permit.accessGeneration) {
      throw StateError('Private playback route generation was revoked');
    }
    final item = await permit.dispatch(
      (c) => (connection?.client ?? c).getItem(source!.itemId),
    );
    if (item.id != source.itemId) throw StateError('Source item mismatch');
    // A library id supplied by a route/IPC message is not membership proof.
    final proofKey = jsonEncode([
      source.item.key,
      library,
      permit.sessionRevision,
      permit.accessGeneration,
    ]);
    final proof = _membershipProofs[proofKey];
    final proven =
        proof != null && DateTime.now().difference(proof) < _membershipProofTtl;
    if (!proven) {
      var ancestor = item;
      final visited = <String>{};
      while (ancestor.id != library) {
        if (!visited.add(ancestor.id) ||
            ancestor.hierarchyParentId == null ||
            visited.length > 32) {
          throw StateError(
            'Playback item does not belong to the permitted library',
          );
        }
        ancestor = await permit.dispatch(
          (c) => (connection?.client ?? c).getItem(ancestor.hierarchyParentId!),
        );
      }
      _rememberMembership(proofKey);
    }
    final work =
        request.work ??
        SourceReference(
          account: account,
          itemId: item.isEpisode ? (item.seriesId ?? '') : item.id,
        );
    if (work.account != account ||
        work.itemId.isEmpty ||
        work.itemId != (item.isEpisode ? item.seriesId : item.id)) {
      throw StateError('Concrete episode has no confirmed series anchor');
    }
    final client = await permit.dispatch((c) async => connection?.client ?? c);
    return PlaybackOrigin(
      source: source,
      work: work.item,
      libraryId: library,
      permit: permit,
      client: client,
      resolvedItem: item,
    );
  }

  /// First-open recovery verifies the candidate before using it for the same
  /// full item/library membership proof used by an ordinary launch.
  Future<PlaybackOrigin> resolveInitialLine(
    PlayerOpenRequest request,
    String lineId,
    Duration timeout,
  ) async {
    final id =
        request.source?.account.configuredServerId ?? auth.session?.server.id;
    if (id == null) throw StateError('Playback source unavailable');
    final session = await registry.ensureSession(id);
    if (request.source != null && request.source!.account != session.account) {
      throw StateError('Playback account changed');
    }
    final permit = registry.permit(session.account);
    final source =
        request.source ??
        SourceReference(
          account: session.account,
          itemId: request.itemId,
          mediaSourceId: request.mediaSourceId,
        );
    final seed = PlaybackOrigin(
      source: source,
      work: request.work ?? source.item,
      libraryId: request.libraryId ?? request.itemId,
      permit: permit,
      client: session.client,
    );
    final connection = await resolveLine(
      seed,
      lineId,
      request.mediaSourceId,
      timeout: timeout,
    );
    return resolve(request, connection: connection);
  }

  /// A local playback boundary may be a season rather than a library. Rebase
  /// it for a different episode, while resolve still verifies the same work,
  /// account and concrete ancestry. Never revive a revoked playback lease.
  Future<PlaybackOrigin> resolveItem(
    PlaybackOrigin origin,
    String itemId, {
    String? mediaSourceId,
  }) async {
    origin.permit.requireValid();
    var library = origin.libraryId;
    if (itemId != origin.source.itemId) {
      final item = await origin.permit.dispatch((c) => c.getItem(itemId));
      if (item.id != itemId) throw StateError('Source item mismatch');
      library = item.hierarchyParentId ?? item.id;
    }
    final resolved = await resolve(
      PlayerOpenRequest(
        itemId: itemId,
        source: SourceReference(
          account: origin.source.account,
          itemId: itemId,
          mediaSourceId: mediaSourceId,
        ),
        work: origin.work,
        libraryId: library,
        mediaSourceId: mediaSourceId,
        accessGeneration: origin.permit.accessGeneration,
      ),
      entry: origin.permit.entry,
    );
    origin.permit.requireValid();
    return resolved;
  }

  /// Old item keys contain endpoint/user/item, not a provider or server ID.
  /// Attribute only an exact, uniquely configured Emby account and version.
  /// Unattributable series-only keys remain stored without being applied.
  Future<void> importLegacyPreferences(
    PlaybackOrigin origin,
    MediaItem item,
    List<PlaybackMediaSource> versions,
    PlayerSettings settings,
  ) async {
    if (origin.source.account.serviceType != MediaServerType.emby ||
        preference(origin, item, versions).failure !=
            PreferenceFailure.notConfigured) {
      return;
    }
    for (final entry in settings.itemPreferences.entries) {
      Object? key;
      try {
        key = jsonDecode(entry.key);
      } catch (_) {
        continue;
      }
      if (key is! List ||
          key.length != 3 ||
          key[0] is! String ||
          key[1] != origin.source.account.userId ||
          key[2] != item.id) {
        continue;
      }
      String address;
      try {
        address = normalizeServerAddress(key[0] as String).toString();
      } catch (_) {
        continue;
      }
      final matching = registry
          .project()
          .where(
            (s) => s.lines.any(
              (line) =>
                  normalizeServerAddress(line.address).toString() == address,
            ),
          )
          .toList();
      if (matching.length != 1 ||
          matching.single.id != origin.source.account.configuredServerId ||
          matching.single.serviceType != MediaServerType.emby) {
        continue;
      }
      final version = versions
          .where((v) => v.id == entry.value.mediaSourceId)
          .toList();
      if (version.length != 1) continue;
      origin.permit.requireValid();
      await history.importAttributedPreference(
        'item:${entry.key}',
        SourcePreference(
          owner: origin.work,
          target: SourceReference(
            account: origin.source.account,
            itemId: item.id,
            mediaSourceId: version.single.id,
          ),
          libraryId: origin.libraryId,
          settings: entry.value,
        ),
        origin.permit,
      );
      return;
    }
  }

  PreferenceResolution preference(
    PlaybackOrigin origin,
    MediaItem item,
    List<PlaybackMediaSource> versions,
  ) {
    final candidates = versions.map(
      (s) => PreferenceCandidate(
        SourceReference(
          account: origin.source.account,
          itemId: item.id,
          mediaSourceId: s.id,
        ),
        origin.libraryId,
        versionName: s.name,
      ),
    );
    var result = history.resolvePreference(
      owner: origin.work,

      candidates: candidates,
      playbackPermit: origin.permit,
    );
    final previous = result.preference;
    // This is an explicit concrete item from the same server's episode picker,
    // not a cross-server mapping of the previously watched episode.
    if (item.isEpisode &&
        item.seriesId == origin.work.itemId &&
        previous != null &&
        previous.target.account == origin.source.account &&
        previous.target.itemId != item.id) {
      result = history.resolvePreference(
        owner: origin.work,

        candidates: candidates,
        playbackPermit: origin.permit,
        nextEpisode: true,
        episodeLookups: {
          origin.source.account: EpisodeLookup(
            EpisodeLookupStatus.confirmed,
            source: EpisodeSource.fromMediaItem(origin.source, item),
          ),
        },
      );
    }
    return result;
  }

  /// Revalidate the concrete equivalence at transaction dispatch, not only the
  /// earlier comparison card. Episode numbering must have been explicitly
  /// verified by the comparison consumer; it is never inferred from item ids.
  Future<void> requireEquivalent(
    PlaybackOrigin original,
    PlaybackOrigin target, {
    String? numberingScheme,
  }) async {
    final oldWork = await original.permit.dispatch(
      (_) => original.client.getItem(original.work.itemId),
    );
    final newWork = await target.permit.dispatch(
      (_) => target.client.getItem(target.work.itemId),
    );
    final index = WorkIndex()
      ..upsert([
        WorkSource.fromMediaItem(original.work, oldWork),
        WorkSource.fromMediaItem(target.work, newWork),
      ]);
    final group = index.groupFor(original.work);
    if (group == null || !group.contains(target.work)) {
      throw StateError('Source equivalence is no longer confirmed');
    }
    final oldItem = await original.permit.dispatch(
      (_) => original.client.getItem(original.source.itemId),
    );
    final newItem = await target.permit.dispatch(
      (_) => target.client.getItem(target.source.itemId),
    );
    if (oldItem.isEpisode || newItem.isEpisode) {
      if (!oldItem.isEpisode || !newItem.isEpisode) {
        throw StateError('Target is not the concrete episode');
      }
      final lookup = locateEpisode(
        series: group,
        origin: EpisodeSource.fromMediaItem(
          original.source,
          oldItem,
          numberingScheme: numberingScheme,
        ),
        targetAccount: target.source.account,
        available: [
          EpisodeSource.fromMediaItem(
            target.source,
            newItem,
            numberingScheme: numberingScheme,
          ),
        ],
      );
      if (lookup.status != EpisodeLookupStatus.confirmed) {
        throw StateError('Concrete episode mapping is uncertain');
      }
    }
  }

  Future<PlaybackOrigin> resolveLine(
    PlaybackOrigin actual,
    String lineId,
    String? version, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    actual.permit.requireValid();
    final server = registry.project().firstWhere(
      (s) => s.id == actual.source.account.configuredServerId,
    );
    final line = server.lines.firstWhere((l) => l.id == lineId);
    final independent =
        registry.createProviderClient?.call(server.serviceType) ??
        registry.createClient();
    if (independent.serviceType != server.serviceType) {
      throw const MediaServerException(
        MediaServerFailureKind.incompatibleServer,
      );
    }
    final address = Uri.parse(line.address);
    final identity = await independent.getPublicInfo(address).timeout(timeout);
    actual.permit.requireValid();
    if (identity.id != actual.source.account.verifiedServerId) {
      throw const MediaServerException(
        MediaServerFailureKind.incompatibleServer,
      );
    }
    independent.attachSession(
      baseUrl: address,
      accessToken: actual.client.accessToken!,
      userId: actual.source.account.userId,
      userAgent: actual.client.customUserAgent,
    );
    try {
      if (registry.sessionIdentityVerifier != null) {
        final stored = await registry.credentials.read(server.id);
        actual.permit.requireValid();
        if (stored == null) throw StateError('Line credential unavailable');
        await registry.verifyAttachedSession(server.id, stored, independent);
      }
      final user = await actual.permit
          .dispatch((_) => independent.getUser())
          .timeout(timeout);
      if (user.id != actual.source.account.userId) {
        throw const MediaServerException(
          MediaServerFailureKind.invalidCredentials,
        );
      }
      final item = await actual.permit
          .dispatch((_) => independent.getItem(actual.source.itemId))
          .timeout(timeout);
      if (item.id != actual.source.itemId) {
        throw const MediaServerException(
          MediaServerFailureKind.incompatibleServer,
        );
      }
      // Validate advertised versions without opening a disposable remote
      // playback. The actual controller owns negotiation and its cleanup lease.
      if (version != null &&
          item.mediaSources.isNotEmpty &&
          !item.mediaSources.any((s) => s.id == version)) {
        throw const PlaybackRecoveryFailure(
          PlaybackRecoveryFailureKind.needsSelection,
        );
      }
      return PlaybackOrigin(
        source: SourceReference(
          account: actual.source.account,
          itemId: item.id,
          mediaSourceId: version,
        ),
        work: actual.work,
        libraryId: actual.libraryId,
        permit: actual.permit,
        client: independent,
      );
    } catch (_) {
      independent.clearSession();
      rethrow;
    }
  }

  Future<WatchSession> begin(PlaybackOrigin origin, String version) =>
      history.beginSession(
        source: SourceReference(
          account: origin.source.account,
          itemId: origin.source.itemId,
          mediaSourceId: version,
        ),
        work: origin.work,
        libraryId: origin.libraryId,
      );

  /// Scope eligibility is independent of whether a fresh registry has acquired
  /// credentials yet. Used to preserve transient ordinary recovery failures.
  bool canRecoverSnapshot(PlaybackSessionSnapshot snapshot) {
    final source = snapshot.source;
    final library = snapshot.libraryId;
    if (source == null ||
        library == null ||
        library.isEmpty ||
        source.itemId != snapshot.itemId ||
        source.mediaSourceId != snapshot.mediaSourceId ||
        snapshot.userId != source.account.userId ||
        snapshot.serviceType != source.account.serviceType ||
        snapshot.position < Duration.zero) {
      return false;
    }
    if (registry.access.isProtected(source.account.configuredServerId) &&
        (!registry.access.allows(source.account.configuredServerId) ||
            snapshot.accessGeneration !=
                registry.access.generation(source.account.configuredServerId) ||
            registry.sessionAccount(
                  source.account.configuredServerId,

                  libraryId: library,
                ) !=
                source.account)) {
      return false;
    }
    return registry.project().any(
      (s) =>
          s.id == source.account.configuredServerId &&
          s.serviceType == source.account.serviceType &&
          s.verifiedServerId == source.account.verifiedServerId &&
          s.cloudAccountId == source.account.cloudAccountId &&
          s.homeUserId == source.account.homeUserId &&
          s.lines.any(
            (l) => Uri.parse(l.address) == Uri.parse(snapshot.baseUrl),
          ),
    );
  }

  Future<bool> recoverSnapshot(
    PlaybackSessionSnapshot snapshot, {
    Future<void> Function(PlaybackSessionSnapshot)? persistRetry,
  }) async {
    final retry = <PlaybackSessionSnapshot>[];
    Object? firstFailure;
    StackTrace? firstStack;
    void rememberFailure(Object error, StackTrace stack) {
      firstFailure ??= error;
      firstStack ??= stack;
    }

    bool permanentlyRevoked(PlaybackSessionSnapshot value, Object error) =>
        !canRecoverSnapshot(value) ||
        error is PlaybackCleanupRevoked ||
        (error is MediaServerException &&
            const {
              MediaServerFailureKind.forbidden,
              MediaServerFailureKind.invalidCredentials,
              MediaServerFailureKind.sessionExpired,
              MediaServerFailureKind.authorizationExpired,
            }.contains(error.kind));

    for (final pending in snapshot.validatedPendingCleanups) {
      try {
        // False means this owner can no longer authorize compensation. Never
        // reacquire the retired source, and do not block independent owners.
        await _recoverSingleSnapshot(pending);
      } catch (error, stack) {
        if (!permanentlyRevoked(pending, error)) {
          retry.add(pending);
          rememberFailure(error, stack);
        }
      }
    }
    var recovered = false;
    var retryPrimary = false;
    try {
      recovered = await _recoverSingleSnapshot(snapshot);
    } catch (error, stack) {
      if (!permanentlyRevoked(snapshot, error)) {
        retryPrimary = true;
        rememberFailure(error, stack);
      }
    }
    if (firstFailure != null) {
      // Persist only retryable children; a successfully reported main session
      // must not produce another watched event while a different owner retries.
      await persistRetry?.call(
        snapshot.withPendingCleanups(
          retry,
          cleanupOnly: !retryPrimary || snapshot.cleanupOnly,
        ),
      );
      Error.throwWithStackTrace(firstFailure!, firstStack!);
    }
    return recovered;
  }

  Future<bool> _recoverSingleSnapshot(PlaybackSessionSnapshot snapshot) async {
    final source = snapshot.source;
    final library = snapshot.libraryId;
    // Legacy/unknown snapshots cannot authorize a request after restart.
    if (source == null ||
        library == null ||
        source.itemId != snapshot.itemId ||
        source.mediaSourceId != snapshot.mediaSourceId ||
        snapshot.userId != source.account.userId ||
        snapshot.position < Duration.zero) {
      return false;
    }
    // Reject removed accounts or revoked entry generations without probing. A missing
    // ordinary session after cold start does not require cloud authentication.
    if (!canRecoverSnapshot(snapshot)) return false;
    return registry.recoverPlayback(
      account: source.account,
      report: playbackReportFromSnapshot(snapshot),
      baseUrl: Uri.parse(snapshot.baseUrl),
      libraryId: library,
      accessGeneration: snapshot.accessGeneration,
      cleanupOnly: snapshot.cleanupOnly,
    );
  }
}
