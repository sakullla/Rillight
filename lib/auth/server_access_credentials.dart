import 'dart:convert';

import 'credential_store.dart';
import 'server_access_store.dart';

/// Uses the application's credential backend, with a separate namespace. This
/// stores salted verifiers only and never persists the user's entry password.
class CredentialServerAccessStore implements ServerAccessStore {
  CredentialServerAccessStore(this.backend);
  final CredentialStore backend;
  String _key(String reference) =>
      'server-access-v1:${base64Url.encode(utf8.encode(reference))}';
  @override
  Future<ServerAccessRecord?> read(String reference) async {
    final value = await backend.read(_key(reference));
    if (value == null) return null;
    return ServerAccessRecord.fromJson(
      (jsonDecode(value.authMaterial['serverAccess']!) as Map)
          .cast<String, dynamic>(),
    );
  }

  @override
  Future<void> write(String reference, ServerAccessRecord record) =>
      backend.write(
        _key(reference),
        StoredCredentials(
          accessToken: '',
          userId: '',
          username: '',
          authMaterial: {'serverAccess': jsonEncode(record.toJson())},
        ),
      );
  @override
  Future<void> delete(String reference) => backend.delete(_key(reference));
}
