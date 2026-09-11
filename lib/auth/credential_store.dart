import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class StoredCredentials {
  const StoredCredentials({
    required this.accessToken,
    required this.userId,
    required this.username,
    this.password,
  });

  final String accessToken;
  final String userId;
  final String username;
  final String? password;

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'userId': userId,
    'username': username,
    if (password != null) 'password': password,
  };

  factory StoredCredentials.fromJson(Map<String, dynamic> json) {
    return StoredCredentials(
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

  @override
  Future<void> write(String serverId, StoredCredentials credentials) async {
    final all = await _readAll();
    all[serverId] = credentials.toJson();
    await _writeAll(all);
  }

  @override
  Future<StoredCredentials?> read(String serverId) async {
    final json = (await _readAll())[serverId];
    if (json is! Map) {
      return null;
    }
    return StoredCredentials.fromJson(Map<String, dynamic>.from(json));
  }

  @override
  Future<void> delete(String serverId) async {
    final all = await _readAll();
    if (all.remove(serverId) != null) {
      await _writeAll(all);
    }
  }

  Future<Map<String, dynamic>> _readAll() async {
    if (!await file.exists()) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      return <String, dynamic>{};
    }
    return <String, dynamic>{};
  }

  Future<void> _writeAll(Map<String, dynamic> values) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(values));
    if (await file.exists()) {
      await file.delete();
    }
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

  static const _keyPrefix = 'rillight.emby.v1.';

  String _key(String serverId) => '$_keyPrefix$serverId';

  @override
  Future<void> write(String serverId, StoredCredentials credentials) async {
    final payload = jsonEncode(credentials.toJson());
    try {
      final writeSecure = _writeSecure;
      if (writeSecure == null) {
        throw const OSError('keychain unavailable');
      }
      await writeSecure(_key(serverId), payload);
    } catch (error) {
      debugPrint(
        'Rillight: keychain write failed, using local credential file: $error',
      );
      await fallback.write(serverId, credentials);
    }
  }

  @override
  Future<StoredCredentials?> read(String serverId) async {
    try {
      final readSecure = _readSecure;
      if (readSecure != null) {
        final raw = await readSecure(_key(serverId));
        if (raw != null && raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            return StoredCredentials.fromJson(
              Map<String, dynamic>.from(decoded),
            );
          }
        }
      }
    } catch (error) {
      debugPrint(
        'Rillight: keychain read failed, using local credential file: $error',
      );
    }
    return fallback.read(serverId);
  }

  @override
  Future<void> delete(String serverId) async {
    try {
      final deleteSecure = _deleteSecure;
      if (deleteSecure != null) {
        await deleteSecure(_key(serverId));
      }
    } catch (error) {
      debugPrint('Rillight: keychain delete failed: $error');
    }
    await fallback.delete(serverId);
  }
}
