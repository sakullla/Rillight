import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/playback_recovery_coordinator.dart';

void main() {
  test('only elapsed signed URL deadlines identify temporary 403', () {
    final now = DateTime.utc(2026, 10, 18);
    expect(
      isExpiredPlaybackUrl(
        Uri.parse('https://cdn.test/file?Expires=1'),
        now: now,
      ),
      isFalse,
    );
    expect(
      isExpiredPlaybackUrl(
        Uri.parse('https://cdn.test/file?Signature=s&Expires=1'),
        now: now,
      ),
      isTrue,
    );
    expect(
      isExpiredPlaybackUrl(
        Uri.parse('https://cdn.test/file?Signature=s&Expires=9999999999'),
        now: now,
      ),
      isFalse,
    );
    expect(
      isExpiredPlaybackUrl(
        Uri.parse(
          'https://cdn.test/file?X-Amz-Signature=s&X-Amz-Date=20261017T000000Z&X-Amz-Expires=60',
        ),
        now: now,
      ),
      isTrue,
    );
  });
  test('one 45 second deadline caps original and every unique candidate', () {
    fakeAsync((clock) {
      final budget = PlaybackRecoveryBudget(elapsed: () => clock.elapsed);
      final tried = <String>[];
      final windows = <Duration>[];
      PlaybackRecoveryCandidate candidate(String id) =>
          PlaybackRecoveryCandidate(id, (window) {
            tried.add(id);
            windows.add(window.remaining);
            return Completer<bool>().future;
          });
      PlaybackRecoveryResult? result;
      PlaybackRecoveryCoordinator()
          .run(
            original: candidate('original'),
            candidates: [
              candidate('a'),
              candidate('a'),
              candidate('b'),
              candidate('c'),
              candidate('d'),
              candidate('e'),
              candidate('f'),
            ],
            lastSuccessfulLineId: 'b',
            budget: budget,
          )
          .then((value) => result = value);
      clock.elapse(const Duration(seconds: 45));
      clock.flushMicrotasks();
      expect(result?.status, PlaybackRecoveryStatus.failed);
      expect(tried, ['original', 'b', 'a', 'c', 'd', 'e']);
      expect(windows, [
        const Duration(seconds: 5),
        ...List.filled(5, const Duration(seconds: 8)),
      ]);
      expect(budget.remaining, Duration.zero);
    });
  });

  test('child deadline is fixed across repeated nested work', () {
    fakeAsync((clock) {
      final root = PlaybackRecoveryBudget(elapsed: () => clock.elapsed);
      final child = root.child(const Duration(seconds: 8));
      clock.elapse(const Duration(seconds: 7));
      expect(child.remaining, const Duration(seconds: 1));
      Object? failure;
      var cancelled = false;
      child
          .run(() => Completer<void>().future, onCancel: () => cancelled = true)
          .catchError((Object error) {
            failure = error;
          });
      clock.elapse(const Duration(seconds: 1));
      expect(failure, isA<TimeoutException>());
      expect(cancelled, isTrue);
      expect(root.remaining, const Duration(seconds: 37));
    });
  });

  test('cancel rejects late success and never starts another line', () async {
    final root = PlaybackRecoveryBudget();
    final pending = Completer<bool>();
    var next = false;
    final task = PlaybackRecoveryCoordinator().run(
      budget: root,
      original: PlaybackRecoveryCandidate('a', (_) => pending.future),
      candidates: [
        PlaybackRecoveryCandidate('b', (_) async {
          next = true;
          return true;
        }),
      ],
    );
    root.cancel();
    expect((await task).status, PlaybackRecoveryStatus.cancelled);
    pending.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(next, isFalse);
  });

  for (final kind in [
    PlaybackRecoveryFailureKind.unauthorized,
    PlaybackRecoveryFailureKind.forbidden,
    PlaybackRecoveryFailureKind.rateLimited,
  ]) {
    test('$kind terminates recovery without bypassing Retry-After', () async {
      var next = false;
      final result = await PlaybackRecoveryCoordinator().run(
        original: PlaybackRecoveryCandidate(
          'a',
          (_) async => throw PlaybackRecoveryFailure(
            kind,
            retryAfter: const Duration(seconds: 90),
          ),
        ),
        candidates: [
          PlaybackRecoveryCandidate('b', (_) async {
            next = true;
            return true;
          }),
        ],
      );
      expect(result.status, PlaybackRecoveryStatus.failed);
      expect(next, isFalse);
    });
  }

  for (final kind in [
    PlaybackRecoveryFailureKind.identity,
    PlaybackRecoveryFailureKind.certificate,
  ]) {
    test('$kind rejects candidate without relaxing validation', () async {
      var calls = 0;
      final result = await PlaybackRecoveryCoordinator().run(
        original: PlaybackRecoveryCandidate('a', (_) async {
          calls++;
          throw PlaybackRecoveryFailure(kind);
        }),
        candidates: [PlaybackRecoveryCandidate('b', (_) async => true)],
      );
      expect(calls, 1);
      expect(result.lineId, 'b');
    });
  }

  test(
    'only identified temporary URL can refresh once within same window',
    () async {
      var calls = 0;
      var refreshes = 0;
      PlaybackRecoveryBudget? first;
      final result = await PlaybackRecoveryCoordinator().run(
        original: PlaybackRecoveryCandidate(
          'a',
          (window) async {
            first ??= window;
            expect(identical(first, window), isTrue);
            calls++;
            throw const PlaybackRecoveryFailure(
              PlaybackRecoveryFailureKind.temporaryUrl,
            );
          },
          refreshUrl: (window) async {
            expect(identical(first, window), isTrue);
            refreshes++;
          },
        ),
        candidates: const [],
      );
      expect(result.status, PlaybackRecoveryStatus.failed);
      expect(calls, 2);
      expect(refreshes, 1);
    },
  );
}
