import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'server_list_store.dart';

export 'server_list_store.dart' show AccessRegion;

enum PrivateAccessState { locked, unlocked, locking }

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

/// Valid only during the single bounded close transaction; not a general permit.
class RestrictedStopPermit {
  RestrictedStopPermit._(this._authority, this.generation);
  final RegionAccessController _authority;
  final int generation;
  bool belongsTo(RegionAccessController authority) =>
      identical(_authority, authority);
  bool get isValid =>
      _authority.state == PrivateAccessState.locking &&
      _authority.generation == generation;
}

typedef RegionCleanup = Future<void> Function(RestrictedStopPermit permit);

class RegionAccessController extends ChangeNotifier {
  RegionAccessController({PinVerifier? verifier, DateTime Function()? clock})
    : _verifier = verifier,
      _clock = clock ?? DateTime.now;
  PinVerifier? _verifier;
  final DateTime Function() _clock;
  PrivateAccessState _state = PrivateAccessState.locked;
  int _generation = 0;
  int _failures = 0;
  DateTime? _retryAt;
  bool _checking = false;
  final Set<RegionCleanup> _cleanup = {};
  final Set<VoidCallback> _revoke = {};
  final Set<VoidCallback> _terminate = {};

  /// Synchronous final eviction/kill hook, also invoked when close times out.
  void addTerminationHook(VoidCallback hook) => _terminate.add(hook);
  void removeTerminationHook(VoidCallback hook) => _terminate.remove(hook);
  Future<void>? _locking;
  PrivateAccessState get state => _state;
  int get generation => _generation;
  bool get hasPin => _verifier != null;
  DateTime? get retryAt => _retryAt;
  bool allows(AccessRegion region) =>
      region == AccessRegion.ordinary || _state == PrivateAccessState.unlocked;
  void addRevocationHook(VoidCallback hook) => _revoke.add(hook);
  void removeRevocationHook(VoidCallback hook) => _revoke.remove(hook);
  void addCleanupHook(RegionCleanup hook) => _cleanup.add(hook);
  void removeCleanupHook(RegionCleanup hook) => _cleanup.remove(hook);
  Future<void> setPin(
    String pin,
    String confirmation,
    Future<void> Function(PinVerifier) persist,
  ) async {
    if (hasPin && !allows(AccessRegion.private)) {
      throw StateError('Unlock required');
    }
    if (pin != confirmation) throw ArgumentError('PIN confirmation differs');
    final verifier = await PinVerifier.create(pin);
    await persist(verifier);
    _verifier = verifier;
    notifyListeners();
  }

  Future<bool> unlock(String pin) async {
    if (_checking ||
        _state == PrivateAccessState.locking ||
        _verifier == null ||
        (_retryAt != null && _clock().isBefore(_retryAt!))) {
      return false;
    }
    _checking = true;
    final captured = generation;
    try {
      final valid = await _verifier!.matches(pin);
      if (captured != generation) return false;
      if (!valid) {
        _failures++;
        _retryAt = _clock().add(
          Duration(seconds: min(60, 1 << min(_failures, 6))),
        );
        notifyListeners();
        return false;
      }
      _failures = 0;
      _retryAt = null;
      _state = PrivateAccessState.unlocked;
      _generation++;
      notifyListeners();
      return true;
    } finally {
      _checking = false;
    }
  }

  Future<void> lock({Duration budget = const Duration(seconds: 3)}) {
    if (_locking != null) return _locking!;
    _state = PrivateAccessState.locking;
    _generation++;
    // Generation is revoked before any external code can observe locking.
    for (final hook in List.of(_revoke)) {
      try {
        hook();
      } catch (_) {}
    }
    notifyListeners();
    final permit = RestrictedStopPermit._(this, generation);
    return _locking = _close(permit, budget);
  }

  Future<void> _close(RestrictedStopPermit permit, Duration budget) async {
    try {
      await Future.wait(
        List.of(_cleanup).map((hook) async {
          try {
            await hook(permit);
          } catch (_) {
            /* no background retry */
          }
        }),
      ).timeout(budget);
    } on TimeoutException {
      /* consumers must terminate residual processes */
    } finally {
      for (final hook in List.of(_terminate)) {
        try {
          hook();
        } catch (_) {
          /* no retry */
        }
      }
      _state = PrivateAccessState.locked;
      _generation++;
      _locking = null;
      notifyListeners();
    }
  }
}
