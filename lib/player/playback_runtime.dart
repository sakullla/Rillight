import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../auth/auth_controller.dart';
import '../auth/source_sessions.dart';
import '../aggregation/history/history_writer.dart';
import '../aggregation/identity/media_identity.dart';
import '../emby/emby_client.dart';
import '../emby/emby_models.dart';
import 'player_window_host.dart';
import 'playback_models.dart';

/// A resolved origin is a lease, not merely a value reference or auth.client.
class PlaybackOrigin {
  const PlaybackOrigin({
    required this.source,
    required this.work,
    required this.libraryId,
    required this.permit,
    required this.client,
  });
  final SourceReference source;
  final SourceReference work;
  final String libraryId;
  final OperationPermit permit;
  final EmbyClient client;
}

/// Created only by the application bootstrap, never by the player helper.
/// All embedded players and desktop IPC share this one history owner.
class PlaybackRuntime {
  PlaybackRuntime({required this.auth, required this.history});
  final AuthController auth;
  final HistoryWriter history;
  SourceSessionRegistry get registry => auth.sources;

  // Navigator page keys bind a mounted route instance, not decoded intent.
  // Imperative routes retain their page key across extra-codec refreshes.
  final Map<Object, PlaybackOrigin? Function()> _mountedPlayers = {};

  void mountPlayer(Object request, PlaybackOrigin? Function() origin) =>
      _mountedPlayers[request] = origin;

  void unmountPlayer(Object request) => _mountedPlayers.remove(request);

  bool hasMountedPlayer(Object request) => _mountedPlayers.containsKey(request);

  PlaybackOrigin? mountedPlayerOrigin(Object request) =>
      _mountedPlayers[request]?.call();

  static Future<PlaybackRuntime> production(AuthController auth) async {
    final root =
        Platform.environment['RILLIGHT_VALIDATION_DATA_DIR'] ??
        '${(await getApplicationSupportDirectory()).path}/rillight';
    final store = await FileHistoryStore.open(File('$root/watch-history.json'));
    return PlaybackRuntime(
      auth: auth,
      history: await HistoryWriter.open(registry: auth.sources, store: store),
    );
  }

  /// 范围许可。库未勾选时返回 null，调用方改用仍有效的服务器会话。
  Future<(SourceAccount, OperationPermit)?> _scopedPlaybackPermit(
    SourceReference source,
    String library,
  ) async {
    try {
      final account = await registry.acquireAccount(
        source.account.configuredServerId,
        region: source.account.region,
        libraryId: library,
      );
      if (account != source.account) {
        throw StateError('Playback account changed');
      }
      return (account, registry.permit(account, libraryId: library));
    } on StateError catch (error) {
      if (error.message != 'Source outside allowed scope') rethrow;
      return null;
    }
  }

  Future<PlaybackOrigin> resolve(PlayerOpenRequest request) async {
    SourceReference? source = request.source;
    String? library = request.libraryId;
    if (source == null) {
      final selected = auth.session?.server;
      if (selected == null) throw StateError('No selected source');
      final allowed = registry
          .project(selected.region)
          .where((s) => s.id == selected.id && s.participates && s.scopeKnown);
      if (allowed.length != 1 || allowed.single.libraryIds.isEmpty) {
        throw StateError('Playback library scope is unknown or unavailable');
      }
      // Acquiring an account does not select a media source or change auth.
      final account = await registry.acquireAccount(
        selected.id,
        region: selected.region,
        libraryId: allowed.single.libraryIds.first,
      );
      final permit = registry.permit(account);
      var item = await permit.dispatch((c) => c.getItem(request.itemId));
      final visited = <String>{};
      while (!allowed.single.libraryIds.contains(item.id)) {
        if (!visited.add(item.id) ||
            item.parentId == null ||
            visited.length > 32) {
          throw StateError('Cannot establish playback library membership');
        }
        item = await permit.dispatch((c) => c.getItem(item.parentId!));
      }
      library = item.id;
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
    if (source.account.region == AccessRegion.private &&
        request.regionGeneration != registry.access.generation) {
      throw StateError('Private playback route generation was revoked');
    }
    // 已勾选的库走范围许可。聚合视界也会打开尚未勾选的库，那种条目只要求
    // 该服务器会话仍然有效，和详情门的 sessionOnly 是同一条规则。
    final scoped = await _scopedPlaybackPermit(source, library);
    final account = scoped?.$1 ?? source.account;
    final permit =
        scoped?.$2 ??
        registry.permit(account, libraryId: library, sessionOnly: true);
    // A decoded route is still only a value reference. Unlocking must not
    // reacquire the authority of a pre-lock private playback intent.
    if (account.region == AccessRegion.private &&
        request.regionGeneration != permit.regionGeneration) {
      throw StateError('Private playback route generation was revoked');
    }
    final item = await permit.dispatch((c) => c.getItem(source!.itemId));
    // A library id supplied by a route/IPC message is not membership proof.
    var ancestor = item;
    final visited = <String>{};
    while (ancestor.id != library) {
      if (!visited.add(ancestor.id) ||
          ancestor.parentId == null ||
          visited.length > 32) {
        throw StateError(
          'Playback item does not belong to the permitted library',
        );
      }
      ancestor = await permit.dispatch((c) => c.getItem(ancestor.parentId!));
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
    final client = await permit.dispatch((c) async => c);
    return PlaybackOrigin(
      source: source,
      work: work.item,
      libraryId: library,
      permit: permit,
      client: client,
    );
  }

  PreferenceResolution preference(
    PlaybackOrigin origin,
    EmbyItem item,
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
      region: origin.source.account.region,
      candidates: candidates,
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
        region: origin.source.account.region,
        candidates: candidates,
        nextEpisode: true,
        episodeLookups: {
          origin.source.account: EpisodeLookup(
            EpisodeLookupStatus.confirmed,
            source: EpisodeSource.fromEmby(origin.source, item),
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
        WorkSource.fromEmby(original.work, oldWork),
        WorkSource.fromEmby(target.work, newWork),
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
        origin: EpisodeSource.fromEmby(
          original.source,
          oldItem,
          numberingScheme: numberingScheme,
        ),
        targetAccount: target.source.account,
        available: [
          EpisodeSource.fromEmby(
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
    final server = registry
        .project(actual.source.account.region)
        .firstWhere((s) => s.id == actual.source.account.configuredServerId);
    final line = server.lines.firstWhere((l) => l.id == lineId);
    final independent = registry.createClient();
    final address = Uri.parse(line.address);
    final identity = await independent.getPublicInfo(address).timeout(timeout);
    actual.permit.requireValid();
    if (identity.id != actual.source.account.verifiedServerId) {
      throw StateError('Line ServerId mismatch');
    }
    independent.attachSession(
      baseUrl: address,
      accessToken: actual.client.accessToken!,
      userId: actual.source.account.userId,
      userAgent: actual.client.customUserAgent,
    );
    try {
      final user = await actual.permit
          .dispatch((_) => independent.getUser())
          .timeout(timeout);
      if (user.id != actual.source.account.userId) {
        throw StateError('Line account mismatch');
      }
      final item = await actual.permit
          .dispatch((_) => independent.getItem(actual.source.itemId))
          .timeout(timeout);
      if (item.id != actual.source.itemId) {
        throw StateError('Line item mismatch');
      }
      final info = await actual.permit
          .dispatch((_) => independent.getPlaybackInfo(itemId: item.id))
          .timeout(timeout);
      if (info.mediaSources.isEmpty ||
          (version != null && !info.mediaSources.any((s) => s.id == version))) {
        throw StateError('Line actual version missing');
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
        snapshot.positionTicks < 0) {
      return false;
    }
    if (source.account.region == AccessRegion.private &&
        (!registry.access.allows(AccessRegion.private) ||
            snapshot.regionGeneration != registry.access.generation ||
            registry.sessionAccount(
                  source.account.configuredServerId,
                  region: source.account.region,
                  libraryId: library,
                ) !=
                source.account)) {
      return false;
    }
    return registry
        .project(source.account.region)
        .any(
          (s) =>
              s.id == source.account.configuredServerId &&
              s.participates &&
              s.scopeKnown &&
              s.libraryIds.contains(library) &&
              s.lines.any(
                (l) => Uri.parse(l.address) == Uri.parse(snapshot.baseUrl),
              ),
        );
  }

  Future<bool> recoverSnapshot(PlaybackSessionSnapshot snapshot) async {
    final source = snapshot.source;
    final library = snapshot.libraryId;
    // Legacy/unknown snapshots cannot authorize a request after restart.
    if (source == null ||
        library == null ||
        source.itemId != snapshot.itemId ||
        source.mediaSourceId != snapshot.mediaSourceId ||
        snapshot.userId != source.account.userId ||
        snapshot.positionTicks < 0) {
      return false;
    }
    // Reject permanent scope/generation removal without probing. A missing
    // ordinary session after cold start is not revocation: acquire it below.
    if (!canRecoverSnapshot(snapshot)) return false;
    final account = await registry.acquireAccount(
      source.account.configuredServerId,
      region: source.account.region,
      libraryId: library,
    );
    if (account != source.account) return false;
    final lines = registry
        .project(source.account.region)
        .firstWhere((s) => s.id == source.account.configuredServerId)
        .lines;
    final savedLines = lines.where(
      (l) => Uri.parse(l.address) == Uri.parse(snapshot.baseUrl),
    );
    if (savedLines.length != 1) return false;
    var origin = await resolve(
      PlayerOpenRequest(
        itemId: snapshot.itemId,
        source: source,
        libraryId: library,
        regionGeneration: snapshot.regionGeneration,
      ),
    );
    if (origin.client.baseUrl != Uri.parse(snapshot.baseUrl)) {
      origin = await resolveLine(
        origin,
        savedLines.single.id,
        snapshot.mediaSourceId,
      );
    } else {
      final info = await origin.permit.dispatch(
        (_) => origin.client.getPlaybackInfo(itemId: snapshot.itemId),
      );
      if (!info.mediaSources.any((s) => s.id == snapshot.mediaSourceId)) {
        return false;
      }
    }
    await origin.permit
        .dispatch(
          (_) => origin.client.reportStopped(
            PlaybackReport.fromSnapshot(snapshot),
          ),
        )
        .timeout(const Duration(seconds: 3));
    return origin.permit.isValid;
  }
}
