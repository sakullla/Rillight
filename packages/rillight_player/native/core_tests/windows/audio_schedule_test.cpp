#include "../../../windows/audio_schedule.h"

#include <cassert>
#include <chrono>

int main() {
  RillightCoreFrame frame{};
  frame.pts_us = 0;
  frame.sample_count = 48000;
  assert(rillight_windows::StartupSampleOffset(frame, 500000, 20000, 1.0) ==
         25440);
  assert(rillight_windows::StartupSampleOffset(frame, 500000, 20000, 2.0) ==
         12720);
  assert(rillight_windows::StartupSampleOffset(frame, 2000000, 0, 1.0) ==
         frame.sample_count);

  RillightCoreSnapshot state{};
  state.state = RILLIGHT_CORE_PLAYING;
  state.queued_video_frames = 1;
  rillight_windows::AudioHandoffPolicy policy;
  const auto now = std::chrono::steady_clock::now();
  assert(!policy.ShouldHandoff(state, false, false, 0, true, now));
  assert(!policy.ShouldHandoff(state, false, false, 0, true,
                               now + std::chrono::milliseconds(149)));
  assert(policy.ShouldHandoff(state, false, false, 0, true,
                              now + std::chrono::milliseconds(150)));
  assert(!policy.ShouldHandoff(state, true, false, 0, true,
                               now + std::chrono::milliseconds(151)));
  state.source_eof = 1;
  assert(policy.ShouldHandoff(state, false, false, 0, true,
                              now + std::chrono::milliseconds(152)));
  policy.Reset();
  state.source_eof = 0;
  state.queued_audio_frames = 2;
  assert(policy.ShouldHandoff(state, true, true, 0, true,
                              now));
  return 0;
}
