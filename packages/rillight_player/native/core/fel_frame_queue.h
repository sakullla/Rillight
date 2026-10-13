#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
extern "C" {
#include <libavutil/avutil.h>
#include <libavutil/frame.h>
#include <libavutil/mathematics.h>
}

namespace rillight::core {
// Allow the HEVC decoded-picture buffer (up to 16 pictures), the base
// decoder's bounded frame threading (up to 8), and 4 conversion-lane frames.
// Decoding a faster EL must not evict pictures still needed by the base.
inline void retain_fel_frame(std::deque<AVFrame*>& frames, AVFrame* decoded) {
  constexpr size_t limit = 32;
  while (frames.size() >= limit) {
    av_frame_free(&frames.front());
    frames.pop_front();
  }
  frames.push_back(decoded);
}

// Match in the stream timestamp domain, before subtracting media origin.
inline AVFrame* take_fel_frame(std::deque<AVFrame*>& frames,
                              AVRational time_base, int64_t pts_us) {
  if (frames.empty()) return nullptr;
  auto release_until = [&](size_t index) {
    AVFrame* found = frames[index];
    for (size_t i = 0; i < index; ++i) av_frame_free(&frames[i]);
    frames.erase(frames.begin(), frames.begin() + static_cast<std::ptrdiff_t>(index) + 1);
    return found;
  };
  auto stamp_us = [&](const AVFrame* frame) {
    int64_t stamp = frame->best_effort_timestamp;
    if (stamp == AV_NOPTS_VALUE) stamp = frame->pts;
    if (stamp == AV_NOPTS_VALUE || time_base.num <= 0 || time_base.den <= 0)
      return static_cast<int64_t>(AV_NOPTS_VALUE);
    return av_rescale_q(stamp, time_base, AVRational{1, 1000000});
  };
  if (pts_us >= 0) {
    size_t best = frames.size();
    int64_t best_delta = 0;
    for (size_t i = 0; i < frames.size(); ++i) {
      const int64_t stamp = stamp_us(frames[i]);
      if (stamp == AV_NOPTS_VALUE) continue;
      const int64_t delta = stamp > pts_us ? stamp - pts_us : pts_us - stamp;
      if (delta <= 2000 && (best == frames.size() || delta < best_delta)) {
        best = i;
        best_delta = delta;
      }
    }
    if (best < frames.size()) return release_until(best);
    while (!frames.empty()) {
      const int64_t stamp = stamp_us(frames.front());
      if (stamp != AV_NOPTS_VALUE && stamp + 2000 < pts_us) {
        av_frame_free(&frames.front());
        frames.pop_front();
        continue;
      }
      break;
    }
    if (!frames.empty() && stamp_us(frames.front()) == AV_NOPTS_VALUE)
      return release_until(0);
    return nullptr;
  }
  return release_until(0);
}
}  // namespace rillight::core
