import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/playback_wake_lock.dart';

void main() {
  test(
    'leases preserve a newer player request when the old player closes',
    () async {
      final calls = <bool>[];
      final coordinator = ScreenWakeLockCoordinator(
        toggle: (value) async => calls.add(value),
      );
      final old = PlaybackWakeLock(coordinator: coordinator);
      final current = PlaybackWakeLock(coordinator: coordinator);
      old.update(true);
      await coordinator.settle();
      current.update(true);
      await old.dispose();
      expect(calls, [true]);
      expect(coordinator.confirmed, isTrue);
      old.update(true);
      await current.dispose();
      expect(calls, [true, false]);
    },
  );

  test(
    'pending enable follows the latest pause or dispose even after a wait timeout',
    () async {
      for (final close in [false, true]) {
        final pending = Completer<void>();
        final calls = <bool>[];
        var nativeEnabled = false;
        final coordinator = ScreenWakeLockCoordinator(
          waitTimeout: const Duration(milliseconds: 10),
          toggle: (value) async {
            calls.add(value);
            if (value) await pending.future;
            nativeEnabled = value;
          },
        );
        final lease = PlaybackWakeLock(coordinator: coordinator)..update(true);
        await (close ? lease.dispose() : lease.release());
        expect(coordinator.pending, isTrue, reason: '$close');
        expect(coordinator.lastError, isA<TimeoutException>());
        expect(calls, [
          true,
        ], reason: 'No parallel off may overtake the pending on');
        pending.complete();
        await coordinator.settle();
        expect(calls, [true, false], reason: '$close');
        expect(nativeEnabled, isFalse, reason: '$close');
        expect(coordinator.confirmed, isFalse, reason: '$close');
        if (close) {
          lease.update(true);
          await coordinator.settle();
          expect(calls, [true, false]);
        }
      }
    },
  );

  test('rapid on off on collapses to the latest desired state', () async {
    final pending = Completer<void>();
    final calls = <bool>[];
    final coordinator = ScreenWakeLockCoordinator(
      toggle: (value) async {
        calls.add(value);
        if (value) await pending.future;
      },
    );
    final lease = PlaybackWakeLock(coordinator: coordinator)..update(true);
    lease.update(false);
    lease.update(true);
    pending.complete();
    await coordinator.settle();
    expect(calls, [true]);
    await lease.dispose();
    expect(calls, [true, false]);
  });

  test('pending off completes before a newer on', () async {
    final off = Completer<void>();
    final calls = <bool>[];
    final coordinator = ScreenWakeLockCoordinator(
      toggle: (value) async {
        calls.add(value);
        if (!value) await off.future;
      },
    );
    final lease = PlaybackWakeLock(coordinator: coordinator)..update(true);
    await coordinator.settle();
    lease.update(false);
    lease.update(true);
    expect(calls, [true, false]);
    off.complete();
    await coordinator.settle();
    expect(calls, [true, false, true]);
    await lease.dispose();
  });

  test(
    'unavailable desktop service reports failure without a retry loop',
    () async {
      var attempts = 0;
      final coordinator = ScreenWakeLockCoordinator(
        toggle: (value) async {
          attempts++;
          if (value) {
            throw StateError('org.freedesktop.portal.Desktop unavailable');
          }
        },
      );
      final lease = PlaybackWakeLock(coordinator: coordinator)..update(true);
      await coordinator.settle();
      for (var i = 0; i < 20; i++) {
        lease.update(true);
      }
      await coordinator.settle();
      expect(attempts, 1);
      expect(lease.diagnostics['error'], contains('unavailable'));
      expect(coordinator.confirmed, isNull);
      await lease.dispose();
      expect(attempts, 2);
      expect(coordinator.confirmed, isFalse);
    },
  );

  test('a failed late enable still receives a compensating off', () async {
    final pending = Completer<void>();
    final calls = <bool>[];
    final coordinator = ScreenWakeLockCoordinator(
      toggle: (value) async {
        calls.add(value);
        if (value) await pending.future;
      },
    );
    final lease = PlaybackWakeLock(coordinator: coordinator)..update(true);
    final closing = lease.dispose();
    pending.completeError(StateError('late failure'));
    await closing;
    expect(calls, [true, false]);
    expect(coordinator.confirmed, isFalse);
  });
}
