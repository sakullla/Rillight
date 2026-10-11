import 'dart:convert';
import 'dart:io';
import '../media_server/capabilities.dart';
import '../media_server/authentication.dart';

import 'package:flutter/foundation.dart';

class StoredCredentials {
  const StoredCredentials({
    required this.accessToken,
    required this.userId,
    required this.username,
    this.password,
    this.serviceType = MediaServerType.emby,
    this.authorizationMethod = AuthorizationMethod.password,
    this.cloudCredentialRef,
    this.cloudAccountId,
    this.homeUserId,
    this.resourceCredentialRef,
    this.authMaterial = const {},
  });

  final MediaServerType serviceType;
  final AuthorizationMethod authorizationMethod;
  final String? cloudCredentialRef;
  final String? cloudAccountId;
  final String? homeUserId;
  final String? resourceCredentialRef;

  /// Provider-owned secrets, never passed to media processes or log output.
  final Map<String, String> authMaterial;
  final String accessToken;
  final String userId;
  final String username;
  final String? password;

  Map<String, dynamic> toJson() => {
    'version': 2,
    'serviceType': serviceType.name,
    'authorizationMethod': authorizationMethod.name,
    'cloudCredentialRef': cloudCredentialRef,
    'cloudAccountId': cloudAccountId,
    'homeUserId': homeUserId,
    'resourceCredentialRef': resourceCredentialRef,
    'authMaterial': authMaterial,
    'accessToken': accessToken,
    'userId': userId,
    'username': username,
    if (password != null) 'password': password,
  };

  factory StoredCredentials.fromJson(Map<String, dynamic> json) {
    if ((json['version'] != null && json['version'] != 2) ||
        json['accessToken'] is! String ||
        json['userId'] is! String ||
        json['username'] is! String) {
      throw const FormatException('Invalid credential record');
    }
    return StoredCredentials(
      serviceType: MediaServerType.values.byName(
        json['serviceType'] as String? ?? 'emby',
      ),
      authorizationMethod: AuthorizationMethod.values.byName(
        json['authorizationMethod'] as String? ?? 'password',
      ),
      cloudCredentialRef: json['cloudCredentialRef'] as String?,
      cloudAccountId: json['cloudAccountId'] as String?,
      homeUserId: json['homeUserId'] as String?,
      resourceCredentialRef: json['resourceCredentialRef'] as String?,
      authMaterial: Map<String, String>.from(
        json['authMaterial'] as Map? ?? {},
      ),
      accessToken: json['accessToken']?.toString() ?? '',
      userId: json['userId']?.toString() ?? '',
      username: json['username']?.toString() ?? '',
      password: json['password']?.toString(),
    );
  }
}

abstract class CredentialStore {
  Future<void> write(String serverId, StoredCredentials credentials);

  Future<StoredCredentials?> read(String serverId);

  Future<void> delete(String serverId);
}

class MemoryCredentialStore implements CredentialStore {
  MemoryCredentialStore([Map<String, StoredCredentials>? seed])
    : _values = Map<String, StoredCredentials>.from(seed ?? const {});

  final Map<String, StoredCredentials> _values;

  @override
  Future<void> write(String serverId, StoredCredentials credentials) async {
    _values[serverId] = credentials;
  }

  @override
  Future<StoredCredentials?> read(String serverId) async => _values[serverId];

  @override
  Future<void> delete(String serverId) async {
    _values.remove(serverId);
  }
}

class FileCredentialStore implements CredentialStore {
  FileCredentialStore(this.file);

  final File file;
  Future<void> _tail = Future.value();
  Future<void> _enqueue(Future<void> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  @override
  Future<void> write(String serverId, StoredCredentials credentials) =>
      _enqueue(() async {
        final all = await _readAll();
        all[serverId] = credentials.toJson();
        await _writeAll(all);
      });

  @override
  Future<StoredCredentials?> read(String serverId) async {
    final json = (await _readAll())[serverId];
    if (json == null) return null;
    if (json is! Map) throw const FormatException('Invalid credential record');
    return StoredCredentials.fromJson(Map<String, dynamic>.from(json));
  }

  @override
  Future<void> delete(String serverId) => _enqueue(() async {
    final all = await _readAll();
    if (all.remove(serverId) != null) await _writeAll(all);
  });

  Future<Map<String, dynamic>> _readAll() async {
    if (!await file.exists()) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid credential document');
      }
      // A malformed sibling must not be silently overwritten during an update.
      for (final value in decoded.values) {
        if (value is! Map) {
          throw const FormatException('Invalid credential record');
        }
        StoredCredentials.fromJson(Map<String, dynamic>.from(value));
      }
      return decoded;
    } on Object {
      throw const FormatException(
        'Invalid credential document; original retained',
      );
    }
  }

  Future<void> _writeAll(Map<String, dynamic> values) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(values));
    await tmp.rename(file.path);
  }
}

class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({
    Future<void> Function(String key, String value)? writeSecure,
    Future<String?> Function(String key)? readSecure,
    Future<void> Function(String key)? deleteSecure,
    required this.fallback,
  }) : _writeSecure = writeSecure,
       _readSecure = readSecure,
       _deleteSecure = deleteSecure;

  final Future<void> Function(String key, String value)? _writeSecure;
  final Future<String?> Function(String key)? _readSecure;
  final Future<void> Function(String key)? _deleteSecure;
  final CredentialStore fallback;

  static const _keyPrefix = 'rillight.media.v2.';
  String _legacyKey(String id) => 'rillight.emby.v1.$id';

  String _key(String serverId) => '$_keyPrefix$serverId';

  Future<void> _tail = Future.value();
  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  String _revocationKey(String id) =>
      'media-revoked-v1:${base64Url.encode(utf8.encode(id))}';
  static const _revoked = StoredCredentials(
    accessToken: '',
    userId: '',
    username: '',
    authMaterial: {'revoked': 'true'},
  );

  @override
  Future<void> write(String serverId, StoredCredentials credentials) =>
      _enqueue(() => _write(serverId, credentials, clearRevocation: true));

  Future<void> _write(
    String serverId,
    StoredCredentials credentials, {
    required bool clearRevocation,
  }) async {
    final payload = jsonEncode(credentials.toJson());
    var secureWritten = false;
    try {
      final writeSecure = _writeSecure;
      if (writeSecure == null) throw const OSError('keychain unavailable');
      await writeSecure(_key(serverId), payload);
      secureWritten = true;
    } catch (_) {
      debugPrint(
        'Rillight: keychain write failed, using local credential file',
      );
      await fallback.write(serverId, credentials);
    }
    if (secureWritten) {
      // A previous fallback must not supersede this successful new login.
      await fallback.delete(serverId);
    }
    if (clearRevocation) await fallback.delete(_revocationKey(serverId));
  }

  @override
  Future<StoredCredentials?> read(String serverId) => _enqueue(() async {
    // This marker survives partial keychain deletion and process restart.
    if (await fallback.read(_revocationKey(serverId)) != null) return null;
    // Fallback is authoritative when a secure write previously failed. A
    // subsequent successful secure write removes it before completing.
    final local = await fallback.read(serverId);
    String? raw;
    var legacy = false;
    try {
      final readSecure = _readSecure;
      if (readSecure != null) {
        raw = await readSecure(_key(serverId));
        legacy = raw == null;
        raw ??= await readSecure(_legacyKey(serverId));
      }
    } catch (_) {
      debugPrint('Rillight: keychain read failed, using local credential file');
      return local;
    }
    if (raw == null) return local;
    late final StoredCredentials value;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Invalid secure credential record');
      }
      value = StoredCredentials.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      throw const FormatException('Invalid secure credential record');
    }
    if (local != null) return local;
    if (legacy) await _write(serverId, value, clearRevocation: false);
    return value;
  });

  @override
  Future<void> delete(String serverId) => _enqueue(() async {
    // Persist revocation first. If this fails, do not partially erase the keys.
    await fallback.write(_revocationKey(serverId), _revoked);
    var failed = false;
    final deleteSecure = _deleteSecure;
    if (deleteSecure != null) {
      for (final key in [_key(serverId), _legacyKey(serverId)]) {
        try {
          await deleteSecure(key);
        } catch (_) {
          failed = true;
        }
      }
    }
    try {
      await fallback.delete(serverId);
    } catch (_) {
      failed = true;
    }
    if (failed) {
      throw const CredentialRevocationException();
    }
    // Keep the nonsecret marker: old backups/keys must not become a new login.
  });
}

class CredentialRevocationException implements Exception {
  const CredentialRevocationException();
  @override
  String toString() =>
      'Credential revocation persisted; credential cleanup incomplete';
}
