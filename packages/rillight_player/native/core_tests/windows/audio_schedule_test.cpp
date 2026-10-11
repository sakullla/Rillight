#include "../../../windows/audio_schedule.h"

#include <cassert>
#include <chrono>
#include <vector>

int main() {
  rillight_windows::PcmOnsetRamp ramp;
  std::vector<int16_t> pcm(480 * 6, 24000);
  // The gain is shared by all channels and continuous across endpoint writes.
  ramp.Apply(pcm.data(), 100, 6);
  ramp.Apply(pcm.data() + 100 * 6, 380, 6);
  for (int i = 0; i < 480; ++i) {
    const auto expected = static_cast<int16_t>(i < 240 ? 24000 * i / 239 : 24000);
    for (int channel = 0; channel < 6; ++channel)
      assert(pcm[i * 6 + channel] == expected);
  }
  ramp.Reset();
  int16_t negative[] = {-32768, 32767, -32768, 32767};
  ramp.Apply(negative, 2, 2);
  assert(negative[0] == 0 && negative[1] == 0);
  assert(negative[2] < 0 && negative[3] > 0);

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
