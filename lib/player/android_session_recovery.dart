import 'package:rillight/player/playback_persistence.dart';
import 'package:rillight/media_server/media_server_client.dart';

import 'playback_runtime.dart';

import 'package:rillight/player/playback_session_snapshot.dart';

/// Compensates an interrupted foreground session only for its original owner.
/// A private client freezes credentials across awaited requests and never
/// refreshes or sends an old report with a newly selected identity.
Future<bool> recoverAndroidSession(
  MediaServerClient client,
  PlaybackSessionSnapshotStore store, {
  PlaybackRuntime? runtime,
}) async {
  if (runtime != null) {
    final snapshot = await store.read();
    if (snapshot == null) return false;
    try {
      if (await runtime.recoverSnapshot(snapshot, persistRetry: store.write)) {
        await store.delete();
        return true;
      }
      // Every entry either completed or permanently lost its authority.
      await store.delete();
      return false;
    } catch (_) {
      if (snapshot.pendingCleanups.isEmpty &&
          !runtime.canRecoverSnapshot(snapshot)) {
        // A revoked compensation is discarded, never kept as a lock-screen
        // retry or resurrected when the same account is unlocked again.
        await store.delete();
        return false;
      }
      rethrow;
    }
  }
  final base = client.baseUrl, user = client.userId, token = client.accessToken;
  if (base == null || user == null || token == null) return false;
  final snapshot = await store.read();
  if (snapshot == null) return false;
  if (snapshot.serviceType != client.serviceType ||
      snapshot.baseUrl != base.toString() ||
      snapshot.userId != user) {
    if (snapshot.pendingCleanups.isEmpty) await store.delete();
    return false;
  }
  if (client.baseUrl != base ||
      client.userId != user ||
      client.accessToken != token) {
    return false;
  }
  final frozen = client.createDetached()
    ..attachSession(
      baseUrl: base,
      userId: user,
      accessToken: token,
      userAgent: client.customUserAgent,
    );
  try {
    // This is a stop-only compensation using an already attached resource
    // credential. In particular, Plex cleanup must not require cloud/Home
    // authorization, and no provider may negotiate a replacement playback.
    if (client.baseUrl != base ||
        client.userId != user ||
        client.accessToken != token) {
      return false;
    }
    for (final pending in snapshot.validatedPendingCleanups) {
      if (pending.serviceType != client.serviceType ||
          pending.baseUrl != base.toString() ||
          pending.userId != user) {
        throw StateError('Pending playback cleanup needs its source authority');
      }
      await frozen
          .releasePlayback(playbackReportFromSnapshot(pending))
          .timeout(const Duration(seconds: 3));
    }
    final report = playbackReportFromSnapshot(snapshot);
    await (snapshot.cleanupOnly
            ? frozen.releasePlayback(report)
            : frozen.stopPlayback(report))
        .timeout(const Duration(seconds: 3));
    await store.delete();
    return true;
  } finally {
    frozen.clearSession();
  }
}
