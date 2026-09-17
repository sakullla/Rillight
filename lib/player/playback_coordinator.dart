/// An operation identity is never reused, even across controllers.
class PlaybackOperation {
  PlaybackOperation._(this.id);
  final int id;
}

class PlaybackCoordinator {
  static int _nextId = 0;
  PlaybackOperation? _current;
  bool _closed = false;
  Future<void> _commands = Future<void>.value();

  PlaybackOperation? get current => _current;
  bool get isClosed => _closed;

  PlaybackOperation? begin() {
    if (_closed) return null;
    return _current = PlaybackOperation._(++_nextId);
  }

  bool accepts(PlaybackOperation? operation) =>
      !_closed && operation != null && identical(_current, operation);

  void invalidate() => _current = null;

  void close() {
    _closed = true;
    invalidate();
  }

  /// Serializes native mutations without letting a failed command poison the
  /// queue. Superseded commands never reach the backend.
  Future<void> run(
    PlaybackOperation operation,
    Future<void> Function() action,
  ) {
    final next = _commands.then((_) async {
      if (accepts(operation)) await action();
    });
    _commands = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> get drained => _commands;

  /// Stop must reach the backend immediately to cancel a pending open. New
  /// mutations still wait for both that cancellation and the previous command.
  Future<void> interrupt(Future<void> Function() stop) {
    final previous = _commands;
    final stopping = Future<void>.sync(stop);
    final barrier = Future.wait([previous, stopping]).then<void>((_) {});
    _commands = barrier.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return barrier;
  }
}
