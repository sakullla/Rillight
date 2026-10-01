#include "../../../windows/audio_schedule.h"

#include <cassert>
#include <chrono>

int main() {
  // Adjacent PCM packets differ by rounding at most; fill the device buffer
  // even when its tail is ahead of the audible clock. A real gap still waits.
  assert(!rillight_windows::WaitForFutureAudio(418474667, 418424666, 418474666));
  assert(!rillight_windows::WaitForFutureAudio(120000, 0, 120000));
  assert(rillight_windows::WaitForFutureAudio(250000, 0, 120000));
  assert(rillight_windows::WaitForFutureAudio(120000, 0, -1));
  RillightCoreFrame frame{};
  frame.pts_us = 0;
  frame.sample_count = 48000;
  assert(rillight_windows::StartupSampleOffset(frame, 500000, 1.0) ==
         24000);
  assert(rillight_windows::StartupSampleOffset(frame, 500000, 2.0) ==
         12000);
  assert(rillight_windows::StartupSampleOffset(frame, 2000000, 1.0) ==
         frame.sample_count);
  frame.sample_count = 960;  // A valid 20 ms first packet must reach WASAPI.
  assert(rillight_windows::StartupSampleOffset(frame, 0, 1.0) == 0);
  assert(rillight_windows::StartupSampleOffset(frame, 10000, 1.0) == 480);
  assert(rillight_windows::StartupSampleOffset(frame, 50000, 1.0) == 960);

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
  state.queued_video_frames = 0;
  assert(!policy.ShouldHandoff(state, false, false, 0, true,
                               now + std::chrono::seconds(10)));
  assert(!policy.ShouldHandoff(state, false, false, 0, true,
                               now + std::chrono::seconds(20)));
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
