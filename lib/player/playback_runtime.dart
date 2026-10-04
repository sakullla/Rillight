import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../auth/auth_controller.dart';
import '../auth/source_sessions.dart';
import '../aggregation/history/history_writer.dart';
import '../aggregation/identity/media_identity.dart';
import '../emby/emby_client.dart';
import 'player_window_host.dart';
import 'playback_models.dart';

/// A resolved origin is a lease, not merely a value reference or auth.client.
class PlaybackOrigin {
  const PlaybackOrigin({required this.source, required this.work,
    required this.libraryId, required this.permit, required this.client});
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

  static Future<PlaybackRuntime> production(AuthController auth) async {
    final root = Platform.environment['RILLIGHT_VALIDATION_DATA_DIR'] ??
        '${(await getApplicationSupportDirectory()).path}/rillight';
    final store = await FileHistoryStore.open(File('$root/watch-history.json'));
    return PlaybackRuntime(auth: auth,
      history: await HistoryWriter.open(registry: auth.sources, store: store));
  }

  Future<PlaybackOrigin> resolve(PlayerOpenRequest request) async {
    SourceReference? source = request.source;
    String? library = request.libraryId;
    if (source == null) {
      final selected = auth.session?.server;
      if (selected == null) throw StateError('No selected source');
      final allowed = registry.project(selected.region)
          .where((s) => s.id == selected.id && s.participates && s.scopeKnown);
      if (allowed.length != 1 || allowed.single.libraryIds.isEmpty) {
        throw StateError('Playback library scope is unknown or unavailable');
      }
      // Acquiring an account does not select a media source or change auth.
      final account = await registry.acquireAccount(selected.id,
        region: selected.region, libraryId: allowed.single.libraryIds.first);
      final permit = registry.permit(account);
      var item = await permit.dispatch((c) => c.getItem(request.itemId));
      final visited = <String>{};
      while (!allowed.single.libraryIds.contains(item.id)) {
        if (!visited.add(item.id) || item.parentId == null || visited.length > 32) {
          throw StateError('Cannot establish playback library membership');
        }
        item = await permit.dispatch((c) => c.getItem(item.parentId!));
      }
      library = item.id;
      source = SourceReference(account: account, itemId: request.itemId,
        mediaSourceId: request.mediaSourceId);
    }
    if (source.itemId != request.itemId || library == null || library.isEmpty) {
      throw ArgumentError('Source and library must belong to playback item');
    }
    final account = await registry.acquireAccount(source.account.configuredServerId,
      region: source.account.region, libraryId: library);
    if (account != source.account) throw StateError('Playback account changed');
    final permit = registry.permit(account, libraryId: library);
    final item = await permit.dispatch((c) => c.getItem(source!.itemId));
    final work = request.work ?? SourceReference(account: account,
      itemId: item.isEpisode ? (item.seriesId ?? '') : item.id);
    if (work.account != account || work.itemId.isEmpty) {
      throw StateError('Concrete episode has no confirmed series anchor');
    }
    final client = await permit.dispatch((c) async => c);
    return PlaybackOrigin(source: source, work: work.item,
      libraryId: library, permit: permit, client: client);
  }

  Future<WatchSession> begin(PlaybackOrigin origin, String version) => history.beginSession(
    source: SourceReference(account: origin.source.account,
      itemId: origin.source.itemId, mediaSourceId: version),
    work: origin.work, libraryId: origin.libraryId);

  Future<bool> recoverSnapshot(PlaybackSessionSnapshot snapshot) async {
    final source = snapshot.source;
    final library = snapshot.libraryId;
    // Legacy/unknown snapshots cannot authorize a request after restart.
    if (source == null || library == null) return false;
    final account = registry.sessionAccount(source.account.configuredServerId,
      region: source.account.region, libraryId: library);
    if (account != source.account) return false;
    final permit = registry.permit(account!, libraryId: library);
    await permit.dispatch((c) => c.reportStopped(PlaybackReport.fromSnapshot(snapshot)))
        .timeout(const Duration(seconds: 3));
    return permit.isValid;
  }
}
