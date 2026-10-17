import 'dart:async';
import 'dart:io';

import '../media_server/errors.dart';

/// A bare HTTP 403 cannot prove URL expiry. Recognize only signed URL formats
/// with an explicit elapsed deadline; unknown formats keep permission semantics.
bool isExpiredPlaybackUrl(Uri? url, {DateTime? now}) {
  if (url == null) return false;
  final query = url.queryParameters;
  final instant = now ?? DateTime.now();
  if (query.containsKey('Signature') || query.containsKey('signature')) {
    final expires = int.tryParse(query['Expires'] ?? query['expires'] ?? '');
    if (expires != null && expires > 0) {
      return expires <= instant.millisecondsSinceEpoch ~/ 1000;
    }
  }
  if (query.containsKey('X-Amz-Signature')) {
    final date = query['X-Amz-Date'] ?? '';
    final lifetime = int.tryParse(query['X-Amz-Expires'] ?? '');
    final pattern = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$')
        .firstMatch(date);
    if (pattern != null && lifetime != null && lifetime >= 0) {
      final start = DateTime.utc(
        int.parse(pattern[1]!),
        int.parse(pattern[2]!),
        int.parse(pattern[3]!),
        int.parse(pattern[4]!),
        int.parse(pattern[5]!),
        int.parse(pattern[6]!),
      );
      return !start.add(Duration(seconds: lifetime)).isAfter(instant);
    }
  }
  return false;
}

/// One monotonic deadline shared by controller, preparation and transport.
class PlaybackRecoveryBudget {
  PlaybackRecoveryBudget({
    this.total = const Duration(seconds: 45),
    this.original = const Duration(seconds: 5),
    this.candidate = const Duration(seconds: 8),
    Duration Function()? elapsed,
  }) : _elapsed = elapsed ?? (Stopwatch()..start()).elapsedGetter,
       _parent = null {
    _deadline = _elapsed() + total;
  }

  PlaybackRecoveryBudget._(PlaybackRecoveryBudget parent, Duration limit)
    : _parent = parent,
      total = parent.total,
      original = parent.original,
      candidate = parent.candidate,
      _elapsed = parent._elapsed {
    _deadline = _elapsed() + _min(limit, parent.remaining);
  }

  final Duration total;
  final Duration original;
  final Duration candidate;
  final Duration Function() _elapsed;
  final PlaybackRecoveryBudget? _parent;
  late final Duration _deadline;
  final _cancellation = Completer<void>();

  Duration get remaining =>
      isCancelled ? Duration.zero : _maxZero(_deadline - _elapsed());
  Duration get remainingForOriginal => _min(remaining, original);
  Duration get remainingForCandidate => _min(remaining, candidate);
  bool get isCancelled =>
      _cancellation.isCompleted || (_parent?.isCancelled ?? false);
  bool get isExpired => remaining <= Duration.zero;
  Future<void> get cancelled => _parent == null
      ? _cancellation.future
      : Future.any([_cancellation.future, _parent.cancelled]);

  PlaybackRecoveryBudget child(Duration limit) =>
      PlaybackRecoveryBudget._(this, limit);

  void check() {
    if (isCancelled) throw const PlaybackRecoveryCancelled();
    if (isExpired) throw TimeoutException('Playback recovery budget exhausted');
  }

  void cancel() {
    if (!_cancellation.isCompleted) _cancellation.complete();
  }

  Future<T> run<T>(
    Future<T> Function() work, {
    Duration? limit,
    void Function()? onCancel,
  }) async {
    check();
    final timeout = limit == null ? remaining : _min(remaining, limit);
    final result = Completer<T>();
    void stop(Object error) {
      if (result.isCompleted) return;
      onCancel?.call();
      result.completeError(error);
    }

    final timer = Timer(
      timeout,
      () => stop(TimeoutException('Playback recovery budget exhausted')),
    );
    unawaited(cancelled.then((_) => stop(const PlaybackRecoveryCancelled())));
    Future<T>.sync(work).then(
      (value) {
        if (result.isCompleted) return;
        try {
          check();
          result.complete(value);
        } catch (error, stack) {
          onCancel?.call();
          result.completeError(error, stack);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    try {
      return await result.future;
    } finally {
      timer.cancel();
    }
  }

  static Duration _min(Duration a, Duration b) => a < b ? a : b;
  static Duration _maxZero(Duration value) =>
      value < Duration.zero ? Duration.zero : value;
}

extension on Stopwatch {
  Duration elapsedGetter() => elapsed;
}

class PlaybackRecoveryCancelled implements Exception {
  const PlaybackRecoveryCancelled();
}

enum PlaybackRecoveryFailureKind {
  network,
  identity,
  certificate,
  unauthorized,
  forbidden,
  temporaryUrl,
  rateLimited,
  needsSelection,
}

class PlaybackRecoveryFailure implements Exception {
  const PlaybackRecoveryFailure(this.kind, {this.retryAfter});
  final PlaybackRecoveryFailureKind kind;
  final Duration? retryAfter;
}

enum PlaybackRecoveryStatus { succeeded, needsSelection, failed, cancelled }

class PlaybackRecoveryResult {
  const PlaybackRecoveryResult(this.status, {this.lineId, this.error});
  final PlaybackRecoveryStatus status;
  final String? lineId;
  final Object? error;
}

class PlaybackRecoveryCandidate {
  const PlaybackRecoveryCandidate(this.lineId, this.attempt, {this.refreshUrl});
  final String lineId;
  final Future<bool> Function(PlaybackRecoveryBudget) attempt;

  /// Only supply when the provider has identified an expired temporary URL.
  final Future<void> Function(PlaybackRecoveryBudget)? refreshUrl;
}

class PlaybackRecoveryCoordinator {
  PlaybackRecoveryBudget? _active;
  void cancel() => _active?.cancel();

  Future<PlaybackRecoveryResult> run({
    required PlaybackRecoveryCandidate original,
    required List<PlaybackRecoveryCandidate> candidates,
    String? lastSuccessfulLineId,
    PlaybackRecoveryBudget? budget,
    void Function(String lineId, bool original)? onAttempt,
  }) async {
    cancel();
    final root = budget ?? PlaybackRecoveryBudget();
    _active = root;
    Object? failure;
    final seen = <String>{original.lineId};
    final alternatives = candidates
        .where((item) => seen.add(item.lineId))
        .toList();
    final recent = alternatives.where(
      (item) => item.lineId == lastSuccessfulLineId,
    );
    final ordered = [
      original,
      ...recent,
      ...alternatives.where((item) => item.lineId != lastSuccessfulLineId),
    ];
    try {
      for (final item in ordered) {
        root.check();
        final first = identical(item, original);
        final window = root.child(first ? root.original : root.candidate);
        onAttempt?.call(item.lineId, first);
        try {
          var refreshed = false;
          while (true) {
            try {
              final succeeded = await window.run(
                () => item.attempt(window),
                onCancel: window.cancel,
              );
              root.check();
              if (succeeded) {
                return PlaybackRecoveryResult(
                  PlaybackRecoveryStatus.succeeded,
                  lineId: item.lineId,
                );
              }
              break;
            } catch (error) {
              final kind = classify(error);
              if (kind == PlaybackRecoveryFailureKind.temporaryUrl &&
                  !refreshed &&
                  item.refreshUrl != null) {
                refreshed = true;
                await window.run(
                  () => item.refreshUrl!(window),
                  onCancel: window.cancel,
                );
                continue;
              }
              if (kind == PlaybackRecoveryFailureKind.rateLimited &&
                  error is PlaybackRecoveryFailure &&
                  error.retryAfter != null) {
                // Waiting never grants a second candidate attempt or extends its deadline.
                final delay = error.retryAfter!;
                if (delay > window.remaining) rethrow;
                await window.run(
                  () => Future<void>.delayed(delay),
                  onCancel: window.cancel,
                );
              }
              rethrow;
            }
          }
        } catch (error) {
          failure = error;
          final kind = classify(error);
          if (root.isCancelled ||
              error is PlaybackRecoveryCancelled && !window.isCancelled) {
            rethrow;
          }
          if (kind == PlaybackRecoveryFailureKind.needsSelection) {
            return PlaybackRecoveryResult(
              PlaybackRecoveryStatus.needsSelection,
              lineId: item.lineId,
              error: error,
            );
          }
          if (kind == PlaybackRecoveryFailureKind.unauthorized ||
              kind == PlaybackRecoveryFailureKind.forbidden ||
              kind == PlaybackRecoveryFailureKind.rateLimited) {
            break;
          }
        } finally {
          window.cancel();
        }
      }
      return PlaybackRecoveryResult(
        PlaybackRecoveryStatus.failed,
        error: failure,
      );
    } on PlaybackRecoveryCancelled catch (error) {
      return PlaybackRecoveryResult(
        PlaybackRecoveryStatus.cancelled,
        error: error,
      );
    } on TimeoutException catch (error) {
      return PlaybackRecoveryResult(
        PlaybackRecoveryStatus.failed,
        error: error,
      );
    } finally {
      if (identical(_active, root)) _active = null;
    }
  }

  static PlaybackRecoveryFailureKind classify(Object error) {
    if (error is PlaybackRecoveryFailure) return error.kind;
    if (error is TlsException) return PlaybackRecoveryFailureKind.certificate;
    if (error is MediaServerException) {
      if (error.statusCode == 401) {
        return PlaybackRecoveryFailureKind.unauthorized;
      }
      return switch (error.kind) {
        MediaServerFailureKind.authorizationExpired ||
        MediaServerFailureKind.invalidCredentials ||
        MediaServerFailureKind.sessionExpired =>
          PlaybackRecoveryFailureKind.unauthorized,
        MediaServerFailureKind.forbidden =>
          PlaybackRecoveryFailureKind.forbidden,
        MediaServerFailureKind.certificate =>
          PlaybackRecoveryFailureKind.certificate,
        MediaServerFailureKind.incompatibleServer =>
          PlaybackRecoveryFailureKind.identity,
        MediaServerFailureKind.rateLimited =>
          PlaybackRecoveryFailureKind.rateLimited,
        _ => PlaybackRecoveryFailureKind.network,
      };
    }
    return PlaybackRecoveryFailureKind.network;
  }
}
