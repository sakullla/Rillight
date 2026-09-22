import 'package:rillight/emby/emby_client.dart';
import 'package:dio/dio.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_session_snapshot.dart';

/// Compensates an interrupted foreground session only for its original owner.
/// A private client freezes credentials across awaited requests and never
/// refreshes or sends an old report with a newly selected identity.
Future<bool> recoverAndroidSession(
  EmbyClient client,
  PlaybackSessionSnapshotStore store,
) async {
  final base = client.baseUrl, user = client.userId, token = client.accessToken;
  if (base == null || user == null || token == null) return false;
  final snapshot = await store.read();
  if (snapshot == null) return false;
  if (snapshot.baseUrl != base.toString() || snapshot.userId != user) {
    await store.delete();
    return false;
  }
  if (client.baseUrl != base ||
      client.userId != user ||
      client.accessToken != token) {
    return false;
  }
  final dio = Dio();
  final frozen = EmbyClient(device: client.device, dio: dio)
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
        .reportStopped(PlaybackReport.fromSnapshot(snapshot))
        .timeout(const Duration(seconds: 3));
    await store.delete();
    return true;
  } finally {
    dio.close(force: true);
  }
}
