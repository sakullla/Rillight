#pragma once

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>

#include "../native/core/rillight_core.h"

namespace rillight_windows {

inline int StartupSampleOffset(const RillightCoreFrame& frame,
                               int64_t position_us, double speed) {
  if (frame.pts_us < 0 || frame.sample_count <= 0 || speed <= 0) return 0;
  // Device latency is queued time, not audio already played by the media clock.
  const double samples =
      (position_us - frame.pts_us) * 48000.0 / (1000000.0 * speed);
  if (samples <= 0) return 0;
  if (samples >= frame.sample_count) return frame.sample_count;
  return static_cast<int>(std::ceil(samples));
}

class AudioHandoffPolicy {
 public:
  bool ShouldHandoff(const RillightCoreSnapshot& state, bool pending_audio,
                     bool future_audio, uint32_t device_padding,
                     bool clock_started,
                     std::chrono::steady_clock::time_point now) {
    const bool drained = state.state == RILLIGHT_CORE_PLAYING &&
                         clock_started && device_padding == 0 &&
                         (future_audio ||
                          (!pending_audio && state.queued_audio_frames == 0));
    if (!drained) {
      since_ = {};
      return false;
    }
    if (state.source_eof || future_audio) return true;
    if (since_ == std::chrono::steady_clock::time_point{}) since_ = now;
    return now - since_ >= std::chrono::milliseconds(150);
  }
  void Reset() { since_ = {}; }

 private:
  std::chrono::steady_clock::time_point since_{};
};

}  // namespace rillight_windows
