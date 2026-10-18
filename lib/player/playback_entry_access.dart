import '../auth/auth_controller.dart';
import 'playback_runtime.dart';

/// A renewed remote token retires playback's request lease but preserves the
/// user's selected account and local entry. Only that case can return to the
/// existing content route; locking or replacing the account exits to home.
bool playbackEntryStillAllowed(AuthController auth, PlaybackOrigin? origin) {
  final session = auth.session;
  if (session == null || origin == null) return false;
  final account = origin.source.account;
  final server = session.server;
  return server.id == account.configuredServerId &&
      server.serviceType == account.serviceType &&
      server.expectedServerId == account.verifiedServerId &&
      server.cloudAccountId == account.cloudAccountId &&
      server.homeUserId == account.homeUserId &&
      session.userId == account.userId &&
      auth.serverAccess.allows(server.id) &&
      auth.serverAccess.generation(server.id) == origin.permit.accessGeneration;
}
