enum PlaybackPhase {
  idle,
  loading,
  playing,
  paused,
  buffering,
  ended,
  failed,
  closing,
  closed,
}

/// Buffering and EOF are independent signals; a pause near the end is not EOF.
class PlaybackState {
  PlaybackPhase phase = PlaybackPhase.idle;
  bool buffering = false;

  void updatePlaying(bool playing) {
    if (phase == PlaybackPhase.closing ||
        phase == PlaybackPhase.closed ||
        phase == PlaybackPhase.failed ||
        phase == PlaybackPhase.ended) {
      return;
    }
    phase = buffering
        ? PlaybackPhase.buffering
        : playing
        ? PlaybackPhase.playing
        : PlaybackPhase.paused;
  }
}
