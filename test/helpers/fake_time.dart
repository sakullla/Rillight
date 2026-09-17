import 'package:fake_async/fake_async.dart';

/// Run a pure in-memory async fixture with its original timer durations.
/// Do not use this around real sockets, files, subprocesses, or widget tests.
Future<void> withFakeTime(Future<void> Function() action) async {
  Object? failure;
  StackTrace? failureStack;
  var finished = false;
  final clock = FakeAsync();
  clock.run((_) {
    action().then(
      (_) => finished = true,
      onError: (Object error, StackTrace stack) {
        failure = error;
        failureStack = stack;
        finished = true;
      },
    );
  });
  for (var turn = 0; turn < 100 && !finished; turn++) {
    clock.flushTimers(
      timeout: const Duration(minutes: 2) - clock.elapsed,
      flushPeriodicTimers: false,
    );
    // Stream cancellation and already-completed Futures can finish in the
    // root zone. Let those microtasks return before flushing the fake zone.
    if (!finished) await Future<void>.delayed(Duration.zero);
  }
  if (failure != null) {
    Error.throwWithStackTrace(failure!, failureStack!);
  }
  if (!finished) {
    throw StateError('The fake-time fixture did not complete.');
  }
}
