import '../media_server/capabilities.dart';
import '../media_server/media_server_client.dart';
import '../plex/plex_authentication.dart';
import '../plex/plex_client.dart';
import 'credential_store.dart';
import 'server_list_store.dart';

/// Prove both the effective Plex user and access to this exact connection.
/// The attached URL may be a manually checked, non-active line.
Future<void> verifyProviderIdentity(
  PlexAuthentication plex,
  SavedServer server,
  StoredCredentials credentials,
  MediaServerClient client,
) async {
  if (server.serviceType != MediaServerType.plex) return;
  if (client is! PlexClient ||
      client.baseUrl == null ||
      server.cloudCredentialRef == null ||
      server.cloudAccountId == null ||
      server.resourceCredentialRef == null ||
      server.verifiedServerId == null) {
    throw StateError('Plex authorization required');
  }
  client.bindVerifiedIdentity(
    await plex.verifyResourceIdentity(
      cloudCredentialRef: server.cloudCredentialRef!,
      resourceCredentialRef: server.resourceCredentialRef!,
      cloudAccountId: server.cloudAccountId!,
      serverId: server.verifiedServerId!,
      userId: credentials.userId,
      resourceToken: credentials.accessToken,
      connection: client.baseUrl!,
      homeUserId: server.homeUserId,
    ),
  );
}
