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
      if (await runtime.recoverSnapshot(snapshot)) {
        await store.delete();
        return true;
      }
      await store.delete();
      return false;
    } catch (_) {
      if (!runtime.canRecoverSnapshot(snapshot)) {
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
    await store.delete();
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
    await frozen.getUser().timeout(const Duration(seconds: 5));
    if (client.baseUrl != base ||
        client.userId != user ||
        client.accessToken != token) {
      return false;
    }
    await frozen
        .stopPlayback(playbackReportFromSnapshot(snapshot))
        .timeout(const Duration(seconds: 3));
    await store.delete();
    return true;
  } finally {
    frozen.clearSession();
  }
}
