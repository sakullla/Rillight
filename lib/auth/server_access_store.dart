import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Same wire format and work factor as the old PIN, without its digits-only UI.
class ServerPasswordVerifier {
  ServerPasswordVerifier({
    required List<int> salt,
    required List<int> hash,
    this.iterations = 210000,
  }) : salt = List.unmodifiable(salt),
       hash = List.unmodifiable(hash);
  final List<int> salt;
  final List<int> hash;
  final int iterations;

  static void validatePassword(String password) {
    if (password.isEmpty || password.length > 1024) {
      throw ArgumentError('Password must contain 1–1024 characters');
    }
  }

  static Future<ServerPasswordVerifier> create(String password) async {
    validatePassword(password);
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    return ServerPasswordVerifier(
      salt: salt,
      hash: await _derive(password, salt, 210000),
    );
  }

  static Future<List<int>> _derive(
    String password,
    List<int> salt,
    int iterations,
  ) async =>
      (await Pbkdf2(
            macAlgorithm: Hmac.sha256(),
            iterations: iterations,
            bits: 256,
          ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt))
          .extractBytes();

  Future<bool> matches(String password) async {
    if (password.isEmpty || password.length > 1024) return false;
    final candidate = await _derive(password, salt, iterations);
    var difference = candidate.length ^ hash.length;
    for (var i = 0; i < hash.length; i++) {
      difference |= candidate[i] ^ hash[i];
    }
    return difference == 0;
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'salt': base64Encode(salt),
    'hash': base64Encode(hash),
    'iterations': iterations,
  };

  factory ServerPasswordVerifier.fromJson(Map<String, dynamic> json) {
    try {
      final salt = base64Decode(json['salt'] as String);
      final hash = base64Decode(json['hash'] as String);
      final iterations = json['iterations'] as int;
      if (json['version'] != 1 ||
          salt.length != 16 ||
          hash.length != 32 ||
          iterations < 100000 ||
          iterations > 1000000) {
        throw const FormatException('Invalid password verifier');
      }
      return ServerPasswordVerifier(
        salt: salt,
        hash: hash,
        iterations: iterations,
      );
    } catch (_) {
      throw const FormatException('Invalid password verifier');
    }
  }
}

class ServerAccessRecord {
  const ServerAccessRecord.protected(this.verifier)
    : unavailable = false,
      enabled = true;
  const ServerAccessRecord.unavailable()
    : verifier = null,
      unavailable = true,
      enabled = true;
  const ServerAccessRecord.disabled()
    : verifier = null,
      unavailable = false,
      enabled = false;
  final ServerPasswordVerifier? verifier;
  final bool unavailable;
  final bool enabled;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'enabled': enabled,
    'unavailable': unavailable,
    'verifier': verifier?.toJson(),
  };

  factory ServerAccessRecord.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 ||
        json['enabled'] is! bool ||
        json['unavailable'] is! bool) {
      throw const FormatException('Invalid server access record');
    }
    if (json['enabled'] == false &&
        json['unavailable'] == false &&
        json['verifier'] == null) {
      return const ServerAccessRecord.disabled();
    }
    if (json['enabled'] == true &&
        json['unavailable'] == true &&
        json['verifier'] == null) {
      return const ServerAccessRecord.unavailable();
    }
    if (json['enabled'] == true &&
        json['unavailable'] == false &&
        json['verifier'] is Map) {
      return ServerAccessRecord.protected(
        ServerPasswordVerifier.fromJson(
          Map<String, dynamic>.from(json['verifier'] as Map),
        ),
      );
    }
    throw const FormatException('Invalid server access record');
  }
}

abstract interface class ServerAccessStore {
  Future<ServerAccessRecord?> read(String reference);
  Future<void> write(String reference, ServerAccessRecord record);
  Future<void> delete(String reference);
}

class MemoryServerAccessStore implements ServerAccessStore {
  final Map<String, ServerAccessRecord> records = {};
  @override
  Future<ServerAccessRecord?> read(String reference) async =>
      records[reference];
  @override
  Future<void> write(String reference, ServerAccessRecord record) async {
    records[reference] = record;
  }

  @override
  Future<void> delete(String reference) async {
    records.remove(reference);
  }
}

/// All callbacks must use platform secure storage. Failure is propagated; no
/// plaintext fallback or silent disabling of protection is allowed.
class SecureServerAccessStore implements ServerAccessStore {
  SecureServerAccessStore({
    required this.readSecure,
    required this.writeSecure,
    required this.deleteSecure,
  });
  final Future<String?> Function(String key) readSecure;
  final Future<void> Function(String key, String value) writeSecure;
  final Future<void> Function(String key) deleteSecure;
  String _key(String reference) =>
      'rillight.server-access.v1.'
      '${base64Url.encode(utf8.encode(reference))}';
  @override
  Future<ServerAccessRecord?> read(String reference) async {
    final raw = await readSecure(_key(reference));
    if (raw == null) return null;
    try {
      return ServerAccessRecord.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      throw const FormatException('Invalid server access record');
    }
  }

  @override
  Future<void> write(String reference, ServerAccessRecord record) =>
      writeSecure(_key(reference), jsonEncode(record.toJson()));
  @override
  Future<void> delete(String reference) => deleteSecure(_key(reference));
}
