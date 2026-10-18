import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Persist this value, never an unlock token or the PIN itself.
class PinVerifier {
  const PinVerifier({
    required this.salt,
    required this.hash,
    this.iterations = 210000,
  });
  final List<int> salt;
  final List<int> hash;
  final int iterations;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'salt': base64Encode(salt),
    'hash': base64Encode(hash),
    'iterations': iterations,
  };
  factory PinVerifier.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unknown PIN version');
    }
    final iterations = json['iterations'] as int;
    final salt = base64Decode(json['salt'] as String);
    final hash = base64Decode(json['hash'] as String);
    if (iterations < 100000 ||
        iterations > 1000000 ||
        salt.length != 16 ||
        hash.length != 32) {
      throw const FormatException('Invalid PIN verifier');
    }
    return PinVerifier(salt: salt, hash: hash, iterations: iterations);
  }
  static Future<PinVerifier> create(String pin) async {
    if (!RegExp(r'^\d{4,12}$').hasMatch(pin)) {
      throw ArgumentError('PIN must contain 4–12 digits');
    }
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    const iterations = 210000;
    final hash = await _derive(pin, salt, iterations);
    return PinVerifier(salt: salt, hash: hash);
  }

  static Future<List<int>> _derive(
    String pin,
    List<int> salt,
    int iterations,
  ) async =>
      (await Pbkdf2(
            macAlgorithm: Hmac.sha256(),
            iterations: iterations,
            bits: 256,
          ).deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: salt))
          .extractBytes();
  Future<bool> matches(String pin) async {
    final candidate = await _derive(pin, salt, iterations);
    var difference = candidate.length ^ hash.length;
    for (var i = 0; i < hash.length; i++) {
      difference |= candidate[i] ^ hash[i];
    }
    return difference == 0;
  }
}
