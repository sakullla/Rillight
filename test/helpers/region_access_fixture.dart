import 'package:rillight/auth/region_access.dart';

/// Business fixtures exercise real access/lock state transitions, without
/// deriving 210,000-round keys for every unrelated navigation or lease case.
/// The production verifier has its own real hashing/persistence regression.
class TestPinVerifier extends PinVerifier {
  TestPinVerifier(this.pin)
    : super(salt: List.filled(16, 0), hash: List.filled(32, 0));

  final String pin;

  static Future<PinVerifier> create(String pin) async {
    if (!RegExp(r'^\d{4,12}$').hasMatch(pin)) {
      throw ArgumentError('PIN must contain 4–12 digits');
    }
    return TestPinVerifier(pin);
  }

  @override
  Future<bool> matches(String pin) async => this.pin == pin;
}

class TestRegionAccessController extends RegionAccessController {
  TestRegionAccessController({super.verifier, super.clock})
    : super(createVerifier: TestPinVerifier.create);
}
