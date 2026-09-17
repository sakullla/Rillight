import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/player/playback_models.dart';

/// Immutable ownership plus a per-session report queue. A later login cannot
/// send this session's progress using another server or user's credentials.
class PlaybackSession {
  PlaybackSession({
    required this.id,
    required this.client,
    required this.report,
  }) : baseUrl = client.baseUrl?.toString(),
       userId = client.userId,
       accessToken = client.accessToken;

  final int id;
  final EmbyClient client;
  final String? baseUrl;
  final String? userId;
  final String? accessToken;
  PlaybackReport report;
  bool stopped = false;
  Future<void> _reports = Future<void>.value();

  bool get ownsCredentials =>
      baseUrl == client.baseUrl?.toString() &&
      userId == client.userId &&
      accessToken == client.accessToken;

  Future<void> enqueue(Future<void> Function() send) {
    final next = _reports.then((_) async {
      if (ownsCredentials) await send();
    });
    _reports = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}
