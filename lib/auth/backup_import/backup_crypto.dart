import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// AES-256-CBC with PKCS7 padding, the only cipher mode the verified backup
/// contracts use. Keys always arrive from the caller; no client constant is
/// embedded in this repository.
final AesCbc _aes256Cbc = AesCbc.with256bits(
  macAlgorithm: MacAlgorithm.empty,
  paddingAlgorithm: PaddingAlgorithm.pkcs7,
);

/// Encrypts [plaintext] and returns only the ciphertext block.
Future<Uint8List> encryptAes256Cbc(
  List<int> plaintext,
  List<int> key,
  List<int> iv,
) async {
  if (key.length != 32 || iv.length != 16) {
    throw ArgumentError.value(
      key,
      'key',
      'expected 32-byte key and 16-byte IV',
    );
  }
  final box = await _aes256Cbc.encrypt(
    plaintext,
    secretKey: SecretKey(key),
    nonce: iv,
  );
  return Uint8List.fromList(box.cipherText);
}

/// Encrypts [plaintext] and returns `IV || ciphertext`, the layout used by the
/// Hills backup JSON `data` field.
Future<Uint8List> encryptAes256CbcPrefixedIv(
  List<int> plaintext,
  List<int> key,
  List<int> iv,
) async {
  final ciphertext = await encryptAes256Cbc(plaintext, key, iv);
  return Uint8List.fromList([...iv, ...ciphertext]);
}

/// Decrypts `IV || ciphertext`. Returns null when [ivAndCiphertext] is not a
/// valid PKCS7-padded AES-256-CBC message under [key], so callers can report a
/// wrong key or damaged payload without echoing diagnostics.
Future<Uint8List?> tryDecryptAes256CbcPrefixedIv(
  List<int> key,
  List<int> ivAndCiphertext,
) async {
  if (key.length != 32) return null;
  if (ivAndCiphertext.length < 32) return null;
  if (ivAndCiphertext.length % 16 != 0) return null;
  final iv = ivAndCiphertext.sublist(0, 16);
  final ciphertext = ivAndCiphertext.sublist(16);
  return _tryDecrypt(key, iv, ciphertext);
}

/// Decrypts [ciphertext] with an explicit [iv], the layout used by the
/// common-config entries where the IV is the first half of the key.
Future<Uint8List?> tryDecryptAes256CbcFixedIv(
  List<int> key,
  List<int> ciphertext,
  List<int> iv,
) async {
  if (key.length != 32 || iv.length != 16) return null;
  if (ciphertext.isEmpty || ciphertext.length % 16 != 0) return null;
  return _tryDecrypt(key, iv, ciphertext);
}

Future<Uint8List?> _tryDecrypt(
  List<int> key,
  List<int> iv,
  List<int> ciphertext,
) async {
  try {
    final clear = await _aes256Cbc.decrypt(
      SecretBox(ciphertext, nonce: iv, mac: Mac.empty),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(clear);
  } catch (_) {
    return null;
  }
}

/// Strict base64 decode; null instead of a FormatException so callers can
/// classify the failure themselves.
Uint8List? tryDecodeBase64(String text) {
  try {
    final decoded = base64.decode(text.trim());
    return Uint8List.fromList(decoded);
  } on FormatException {
    return null;
  }
}
