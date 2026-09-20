import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// Stateless session-local routes. Evicting cache metadata cannot invalidate a
/// URL in an already issued playlist. The player receives no upstream secrets.
class SealedMediaRoutes {
  final _cipher = DartAesGcm.with256bits();
  final _key = SecretKeyData(
    List<int>.generate(32, (_) => Random.secure().nextInt(256)),
  );
  final _hash = const DartSha256();

  String seal(Uri url, int role, String context) {
    final bytes = utf8.encode(jsonEncode([url.toString(), role, context]));
    final box = _cipher.encryptSync(bytes, secretKeyData: _key);
    return base64Url.encode(box.concatenation()).replaceAll('=', '');
  }

  ({Uri url, int role, String identity})? open(String token) {
    if (token.length > 65536) return null;
    try {
      final box = SecretBox.fromConcatenation(
        base64Url.decode(base64Url.normalize(token)),
        nonceLength: _cipher.nonceLength,
        macLength: _cipher.macAlgorithm.macLength,
      );
      final bytes = _cipher.decryptSync(box, secretKeyData: _key);
      final values = jsonDecode(utf8.decode(bytes));
      if (values is! List ||
          values.length != 3 ||
          values[0] is! String ||
          values[1] is! int ||
          values[2] is! String) {
        return null;
      }
      final url = Uri.parse(values[0] as String);
      if (url.scheme != 'http' && url.scheme != 'https') return null;
      final identity = _hash
          .hashSync(bytes)
          .bytes
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join();
      return (url: url, role: values[1] as int, identity: identity);
    } catch (_) {
      return null;
    }
  }

  void close() => _key.destroy();
}
