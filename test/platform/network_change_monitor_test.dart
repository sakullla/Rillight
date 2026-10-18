import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/platform/network_change_monitor.dart';

void main() {
  test('interface jitter merges and disposal cancels late notification', () {
    fakeAsync((clock) {
      var interfaces = ['wifi'];
      var events = 0;
      final monitor = NetworkChangeMonitor(
        snapshot: () async => List.of(interfaces),
        pollInterval: const Duration(milliseconds: 100),
        debounce: const Duration(milliseconds: 250),
      );
      final subscription = monitor.changes.listen((_) => events++);
      clock.flushMicrotasks();
      expect(events, 0);
      interfaces = ['cellular'];
      clock.elapse(const Duration(milliseconds: 100));
      interfaces = ['wifi'];
      clock.elapse(const Duration(milliseconds: 100));
      interfaces = ['vpn', 'wifi'];
      clock.elapse(const Duration(milliseconds: 400));
      expect(events, 1);
      interfaces = ['wifi'];
      clock.elapse(const Duration(milliseconds: 100));
      unawaited(subscription.cancel());
      unawaited(monitor.dispose());
      clock.elapse(const Duration(seconds: 2));
      expect(events, 1);
    });
  });
}
