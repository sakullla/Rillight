import 'dart:async';

import 'package:wakelock_plus/wakelock_plus.dart';

/// One process-wide platform request, shared by all live playback leases.
/// A failed request is attempted again only after a real lease transition.
class ScreenWakeLockCoordinator {
  ScreenWakeLockCoordinator({
    Future<void> Function(bool)? toggle,
    this.waitTimeout = const Duration(seconds: 1),
  }) : _toggle = toggle ?? _platformToggle;

  static final shared = ScreenWakeLockCoordinator();
  final Future<void> Function(bool) _toggle;
  final Duration waitTimeout;
  final _owners = <Object>{};
  bool? _confirmed = false;
  int _revision = 0;
  int _processed = 0;
  Future<void>? _draining;
  Object? lastError;

  bool get desired => _owners.isNotEmpty;
  bool? get confirmed => _confirmed;
  bool get pending => _draining != null;

  static Future<void> _platformToggle(bool enabled) async {
    await WakelockPlus.toggle(enable: enabled);
    if (await WakelockPlus.enabled != enabled) {
      throw StateError(
        'The platform did not acknowledge the display wake lock',
      );
    }
  }

  void _update(Object owner, bool enabled) {
    final changed = enabled ? _owners.add(owner) : _owners.remove(owner);
    if (!changed) return;
    ++_revision;
    if (_draining == null) {
      final done = Completer<void>();
      _draining = done.future;
      unawaited(_drain(done));
    }
  }

  Future<void> _drain(Completer<void> done) async {
    try {
      while (_processed != _revision) {
        _processed = _revision;
        final enabled = desired;
        if (_confirmed == enabled) continue;
        try {
          // Do not timeout/cancel this operation and start another toggle in
          // parallel. A late enable must finish before its compensating off.
          await _toggle(enabled);
          _confirmed = enabled;
          lastError = null;
        } catch (error) {
          _confirmed = null;
          lastError = error;
        }
      }
    } finally {
      _draining = null;
      done.complete();
    }
  }

  /// Playback/close need not wait forever for a desktop service. The actual
  /// serial drain remains alive after this deadline and will apply the latest
  /// desired state if an outstanding platform operation eventually completes.
  Future<void> settle() async {
    final draining = _draining;
    if (draining == null) return;
    try {
      await draining.timeout(waitTimeout);
    } on TimeoutException catch (error) {
      lastError = error;
    }
  }
}

class PlaybackWakeLock {
  PlaybackWakeLock({ScreenWakeLockCoordinator? coordinator})
    : _coordinator = coordinator ?? ScreenWakeLockCoordinator.shared;

  final ScreenWakeLockCoordinator _coordinator;
  final _owner = Object();
  bool _active = false;
  bool _closed = false;

  void update(bool active) {
    if (_closed || active == _active) return;
    _active = active;
    _coordinator._update(_owner, active);
  }

  Future<void> release() {
    update(false);
    return _coordinator.settle();
  }

  Future<void> dispose() {
    disposeNow();
    return _coordinator.settle();
  }

  /// Widget disposal cannot await a platform service or leave a timeout timer
  /// in the widget test clock. The coordinator still serializes the release.
  void disposeNow() {
    update(false);
    _closed = true;
  }

  Map<String, Object?> get diagnostics => {
    'requested': _active,
    'processDesired': _coordinator.desired,
    'confirmed': _coordinator.confirmed,
    'pending': _coordinator.pending,
    if (_coordinator.lastError != null)
      'error': _coordinator.lastError.toString(),
  };
}
