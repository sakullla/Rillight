import 'capabilities.dart';
import 'models.dart';

enum AuthorizationMethod { password, quickConnect, browserPin }

enum AuthorizationStatus { pending, authorized, denied, expired, cancelled }

enum ServerConnectionKind { local, remote, relay }

class ServerConnection {
  const ServerConnection(this.uri, this.kind, {this.limitedBandwidth = false});
  final Uri uri;
  final ServerConnectionKind kind;
  final bool limitedBandwidth;
}

/// An authorization reference, not a display name or a server resource token.
class CloudAccount {
  const CloudAccount({
    required this.id,
    required this.name,
    required this.credentialRef,
  });
  final String id;
  final String name;
  final String credentialRef;
}

class HomeUser {
  const HomeUser({
    required this.id,
    required this.name,
    required this.requiresPin,
  });
  final String id;
  final String name;
  final bool requiresPin;
}

class AuthorizedServerResource {
  const AuthorizedServerResource({
    required this.serviceType,
    required this.server,
    required this.user,
    required this.resourceCredentialRef,
    required this.connections,
    this.cloudAccountId,
    this.homeUserId,
    this.owned,
  });
  final bool? owned;
  final MediaServerType serviceType;
  final PublicServerInfo server;
  final MediaUser user;
  final String resourceCredentialRef;
  final List<ServerConnection> connections;
  final String? cloudAccountId;
  final String? homeUserId;
}

/// Providers keep polling secrets and JWK material inside the attempt/store.
/// An authorized poll is not a login until exchange verifies the target user.
abstract interface class AuthorizationAttempt {
  String get code;
  Uri? get verificationUri;
  DateTime get expiresAt;
  Duration get pollInterval;
  Future<AuthorizationStatus> poll();
  Future<AuthorizationGrant> exchange();
  Future<void> cancel();
}

abstract interface class InteractiveAuthentication {
  Future<CapabilityStatus> availability(
    AuthorizationMethod method, {
    Uri? server,
  });
  Future<AuthorizationAttempt> begin(AuthorizationMethod method, {Uri? server});
}

abstract interface class AccountResourceAuthentication {
  Future<CloudAccount> restoreAccount(String credentialRef);
  Future<List<AuthorizedServerResource>> discoverResources(
    CloudAccount account,
  );
  Future<List<HomeUser>> homeUsers(CloudAccount account);
  Future<List<AuthorizedServerResource>> switchHomeUser(
    CloudAccount account,
    HomeUser user, {
    String? pin,
  });
  Future<void> refreshAccount(CloudAccount account);
  Future<void> revokeAccount(CloudAccount account);
}

sealed class AuthorizationGrant {
  const AuthorizationGrant();
}

class SessionAuthorizationGrant extends AuthorizationGrant {
  const SessionAuthorizationGrant(this.session);
  final AuthenticationResult session;
}

class CloudAuthorizationGrant extends AuthorizationGrant {
  const CloudAuthorizationGrant(this.account);
  final CloudAccount account;
}
