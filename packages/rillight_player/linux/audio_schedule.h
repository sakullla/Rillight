#pragma once

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>

#include "../native/core/rillight_core.h"

namespace rillight_linux {

// The first sample committed to a newly ready device must not pull the media
// clock behind video already shown while that device was connecting.
inline int StartOffset(const RillightCoreFrame& frame, int64_t position_us,
                       double speed) {
  if (frame.pts_us < 0 || position_us <= frame.pts_us ||
      speed <= 0 || frame.sample_count <= 0) return 0;
  const double samples = (position_us - frame.pts_us) * 48000.0 /
                         (1000000.0 * speed);
  if (samples >= frame.sample_count) return frame.sample_count * 4;
  return std::max(0, static_cast<int>(std::ceil(samples))) * 4;
}

inline int64_t StartupAudioTarget(int64_t position_us, int64_t frame_pts_us) {
  // A device's first timing report includes its startup queue. When video has
  // already advanced, queue PCM slightly ahead so that subtracting that delay
  // cannot rewind the core clock. Never trim the opening sample at position 0.
  if (position_us <= 10000 || frame_pts_us > position_us + 50000)
    return position_us;
  return position_us > std::numeric_limits<int64_t>::max() - 30000
      ? std::numeric_limits<int64_t>::max() : position_us + 30000;
}

class AudioStartupGate {
 public:
  bool HoldVideo(const RillightCoreSnapshot& snapshot,
                 const RillightCoreFrame* pending, bool audio_clock_started,
                 bool audio_output_queued,
                 std::chrono::steady_clock::time_point now) {
    if (snapshot.state != RILLIGHT_CORE_PLAYING ||
        snapshot.audio_stream_index < 0 || audio_clock_started) {
      waiting_since_ = {};
      return false;
    }
    if (pending && pending->pts_us >= 0)
      return pending->pts_us <= snapshot.position_us + 50000;
    if (audio_output_queued) return true;
    // The first audio packet may start late in an otherwise valid video. Give
    // interleaved demux a short chance to produce it, then let video run. The
    // first PCM write skips samples already behind that video clock.
    if (waiting_since_ == std::chrono::steady_clock::time_point{})
      waiting_since_ = now;
    return now - waiting_since_ < std::chrono::milliseconds(150);
  }
  void Reset() { waiting_since_ = {}; }
 private:
  std::chrono::steady_clock::time_point waiting_since_{};
};

class AudioHandoffPolicy {
 public:
  bool ShouldHandoff(const RillightCoreSnapshot& snapshot,
                     bool pending_audio, int64_t device_delay_us,
                     bool clock_started,
                     std::chrono::steady_clock::time_point now) {
    const bool drained = snapshot.state == RILLIGHT_CORE_PLAYING &&
                         snapshot.queued_video_frames > 0 &&
                         snapshot.queued_audio_frames == 0 &&
                         !pending_audio && clock_started &&
                         device_delay_us >= 0 && device_delay_us <= 1000;
    if (!drained) {
      drained_since_ = {};
      reported_ = false;
      return false;
    }
    if (drained_since_ == std::chrono::steady_clock::time_point{})
      drained_since_ = now;
    if (reported_ || now - drained_since_ < std::chrono::milliseconds(150))
      return false;
    reported_ = true;
    return true;
  }
  void Reset() {
    drained_since_ = {};
    reported_ = false;
  }
 private:
  std::chrono::steady_clock::time_point drained_since_{};
  bool reported_ = false;
};

// A frame may exceed the device's 10 ms write quantum. Consume every
// immediately writable chunk before sleeping, with a finite per-pass budget.
template <typename Write, typename Report>
int DrainPcm(const uint8_t* data, int bytes, int offset,
             Write write, Report report, int byte_budget = 19200) {
  const int limit = std::min(bytes, offset + std::max(0, byte_budget));
  for (int calls = 0; calls < 32 && offset < limit; ++calls) {
    const size_t written = write(data + offset,
                                 static_cast<size_t>(limit - offset));
    if (!written) break;
    offset += static_cast<int>(written);
    report(offset);
  }
  return offset;
}

}  // namespace rillight_linux
