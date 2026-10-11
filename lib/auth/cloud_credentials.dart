import 'dart:convert';

import '../media_server/authentication.dart';
import '../media_server/capabilities.dart';
import 'credential_store.dart';

/// Secret account/device/resource material stored using the host credential
/// backend. Source clients receive only their own resource token.
class StoredCloudCredentials {
  const StoredCloudCredentials({
    required this.accountId,
    required this.accessToken,
    required this.deviceId,
    this.refreshToken,
    this.signingKey,
    this.expiresAt,
    this.providerData = const {},
  });
  final String accountId;
  final String accessToken;
  final String deviceId;
  final String? refreshToken;
  final Map<String, dynamic>? signingKey;
  final DateTime? expiresAt;
  final Map<String, dynamic> providerData;
  Map<String, dynamic> toJson() => {
    ...providerData,
    'accountId': accountId,
    'accessToken': accessToken,
    'deviceId': deviceId,
    if (refreshToken != null) 'refreshToken': refreshToken,
    if (signingKey != null) 'signingKey': signingKey,
    if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
  };
  factory StoredCloudCredentials.fromJson(Map<String, dynamic> json) =>
      StoredCloudCredentials(
        accountId: json['accountId'] as String? ?? '',
        accessToken: json['accessToken'] as String? ?? '',
        deviceId: json['deviceId'] as String? ?? '',
        refreshToken: json['refreshToken'] as String?,
        signingKey: (json['signingKey'] as Map?)?.cast<String, dynamic>(),
        expiresAt: json['expiresAt'] == null
            ? null
            : DateTime.parse(json['expiresAt'] as String),
        providerData: Map.unmodifiable(json),
      );
}

class CloudCredentialStore {
  const CloudCredentialStore(this.backend);
  final CredentialStore backend;
  String _key(String ref) =>
      'media-cloud-v1:${base64Url.encode(utf8.encode(ref))}';
  Future<Map<String, dynamic>?> readCredential(String ref) async {
    final stored = await backend.read(_key(ref));
    if (stored == null) return null;
    if (stored.serviceType != MediaServerType.plex) {
      throw const FormatException('Invalid cloud credential provider');
    }
    return (jsonDecode(stored.authMaterial['providerData']!) as Map)
        .cast<String, dynamic>();
  }

  Future<void> writeCredential(String ref, Map<String, dynamic> value) =>
      backend.write(
        _key(ref),
        StoredCredentials(
          accessToken: value['accessToken'] as String? ?? '',
          userId: value['accountId'] as String? ?? '',
          username: '',
          serviceType: MediaServerType.plex,
          authorizationMethod: AuthorizationMethod.browserPin,
          authMaterial: {'providerData': jsonEncode(value)},
        ),
      );
  Future<void> deleteCredential(String ref) => backend.delete(_key(ref));
  Future<StoredCloudCredentials?> read(String ref) async {
    final value = await readCredential(ref);
    return value == null ? null : StoredCloudCredentials.fromJson(value);
  }

  Future<void> write(String ref, StoredCloudCredentials value) =>
      writeCredential(ref, value.toJson());
}
