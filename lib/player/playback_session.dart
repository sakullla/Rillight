import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/playback.dart';

import '../auth/source_sessions.dart';
import '../media_server/resources.dart';
import '../aggregation/history/history_writer.dart';

/// Immutable ownership plus a per-session report queue. A later login cannot
/// send this session's progress using another server or user's credentials.
class PlaybackSession {
  PlaybackSession({
    required this.id,
    required this.client,
    required this.report,
    this.permit,
    this.frozenStop,
    this.resources,
  }) : baseUrl = client.baseUrl?.toString(),
       userId = client.userId,
       accessToken = client.accessToken;

  final int id;
  final PlaybackResourceLease? resources;
  final MediaServerClient client;
  final String? baseUrl;
  final String? userId;
  final String? accessToken;
  PlaybackReport report;
  bool stopped = false;
  bool revoked = false;
  final OperationPermit? permit;
  final FrozenSourceStop? frozenStop;
  WatchSession? watchSession;
  int eventSequence = 0;
  bool actuallyStarted = false;
  int? lastObservedPositionTicks;
  WatchRecord? lastRecord;
  Future<void> observations = Future<void>.value();
  Future<void> _reports = Future<void>.value();

  bool get ownsCredentials =>
      (permit?.isValid ?? true) &&
      baseUrl == client.baseUrl?.toString() &&
      userId == client.userId &&
      accessToken == client.accessToken;

  Future<void> enqueue(Future<void> Function() send) {
    final next = _reports.then((_) async {
      if (!revoked && ownsCredentials) await send();
    });
    _reports = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}
