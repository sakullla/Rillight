/// Playing → Progress → Stopped. Progress is rejected after Stopped.
class PlaybackCheckInMachine {
  bool _started = false;
  bool _stopped = false;

  bool get isStarted => _started;
  bool get isStopped => _stopped;
  bool get canProgress => _started && !_stopped;

  void start() {
    _started = true;
    _stopped = false;
  }

  /// Returns false if Stopped was already sent or playback never started.
  bool stop() {
    if (_stopped || !_started) {
      _stopped = true;
      return false;
    }
    _stopped = true;
    _started = false;
    return true;
  }
}
