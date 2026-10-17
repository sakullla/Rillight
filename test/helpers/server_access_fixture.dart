import 'package:rillight/auth/server_access.dart';

/// Keeps unrelated navigation/lease tests fast while exercising the production
/// per-server permit and revocation controller. Hashing has dedicated tests.
class TestPasswordVerifier extends ServerPasswordVerifier {
  TestPasswordVerifier(this.password)
    : super(salt: List.filled(16, 0), hash: List.filled(32, 0));

  final String password;

  static Future<ServerPasswordVerifier> create(String password) async {
    ServerPasswordVerifier.validatePassword(password);
    return TestPasswordVerifier(password);
  }

  @override
  Future<bool> matches(String password) async => this.password == password;
}

class TestServerAccessController extends ServerAccessController {
  TestServerAccessController({
    ServerAccessStore? store,
    Map<String, String> passwords = const {},
    super.clock,
  }) : super(
         store: store ?? _store(passwords),
         createVerifier: TestPasswordVerifier.create,
       );

  static MemoryServerAccessStore _store(Map<String, String> passwords) =>
      MemoryServerAccessStore()
        ..records.addAll({
          for (final entry in passwords.entries)
            'test:${entry.key}': ServerAccessRecord.protected(
              TestPasswordVerifier(entry.value),
            ),
        });
}
