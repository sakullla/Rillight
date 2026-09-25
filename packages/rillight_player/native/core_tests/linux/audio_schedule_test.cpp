#include "../../../linux/audio_schedule.h"

#include <cassert>
#include <chrono>
#include <cstdint>

int main() {
  uint8_t pcm[11520]{};  // 60 ms stereo S16 at 48 kHz.
  int writes = 0;
  int reported = 0;
  const int offset = rillight_linux::DrainPcm(
      pcm, sizeof(pcm), 0,
      [&](const uint8_t*, size_t available) {
        ++writes;
        return std::min(available, size_t{1920});
      },
      [&](int sent) { reported = sent; });
  assert(offset == sizeof(pcm) && writes == 6 && reported == offset);
  writes = 0;
  assert(rillight_linux::DrainPcm(
      pcm, sizeof(pcm), 0,
      [&](const uint8_t*, size_t available) {
        ++writes;
        return std::min(available, size_t{1920});
      }, [](int) {}, 3840) == 3840);
  assert(writes == 2);

  RillightCoreFrame frame{};
  frame.pts_us = 1000000;
  frame.sample_count = 4800;
  assert(rillight_linux::StartOffset(frame, 1050000, 1.0) == 9600);
  assert(rillight_linux::StartOffset(frame, 1050000, 2.0) == 4800);
  assert(rillight_linux::StartOffset(frame, 1200000, 1.0) == 19200);
  assert(rillight_linux::StartOffset(frame, INT64_MAX, 0.5) == 19200);
  frame.sample_count = 960;  // Twenty milliseconds per PCM packet.
  for (int64_t opening_position : {int64_t{0}, int64_t{200000}}) {
    bool opening_clock_started = false;
    int opening_packets_written = 0;
    if (opening_position > 0) {
      frame.pts_us = opening_position - 20000;
      assert(rillight_linux::StartOffset(frame, opening_position, 1.0) ==
             frame.sample_count * 4);
    }
    for (int packet = 0; packet < 3; ++packet) {
      frame.pts_us = opening_position + packet * 20000;
      const int first_byte = opening_clock_started ? 0 :
          rillight_linux::StartOffset(frame, opening_position, 1.0);
      assert(first_byte == 0);
      const int sent = rillight_linux::DrainPcm(
          pcm, frame.sample_count * 4, first_byte,
          [](const uint8_t*, size_t available) { return available; },
          [&](int sent_bytes) {
            const int64_t end_pts = frame.pts_us +
                sent_bytes / 4 * 1000000LL / 48000;
            // The core clamps a high-latency report to the current position.
            assert(std::max(opening_position, end_pts - 80000) ==
                   opening_position);
            opening_clock_started = true;
          });
      assert(sent == frame.sample_count * 4);
      ++opening_packets_written;
    }
    assert(opening_packets_written == 3 && opening_clock_started);
  }
  frame.pts_us = 1000000;

  RillightCoreSnapshot snapshot{};
  snapshot.state = RILLIGHT_CORE_PLAYING;
  snapshot.audio_stream_index = 1;
  snapshot.position_us = 1000000;
  rillight_linux::AudioStartupGate startup;
  const auto startup_now = std::chrono::steady_clock::now();
  assert(startup.HoldVideo(snapshot, nullptr, false, false, startup_now));
  assert(startup.HoldVideo(snapshot, nullptr, false, false,
                           startup_now + std::chrono::milliseconds(149)));
  assert(!startup.HoldVideo(snapshot, nullptr, false, false,
                            startup_now + std::chrono::milliseconds(150)));
  assert(startup.HoldVideo(snapshot, &frame, false, false,
                           startup_now + std::chrono::milliseconds(151)));
  assert(!startup.HoldVideo(snapshot, &frame, true, false,
                            startup_now + std::chrono::milliseconds(151)));
  frame.pts_us = 2000000;
  assert(!startup.HoldVideo(snapshot, &frame, false, false,
                            startup_now + std::chrono::milliseconds(152)));
  assert(startup.HoldVideo(snapshot, nullptr, false, true,
                           startup_now + std::chrono::seconds(1)));

  rillight_linux::AudioHandoffPolicy handoff;
  snapshot.queued_video_frames = 2;
  snapshot.queued_audio_frames = 0;
  const auto now = std::chrono::steady_clock::now();
  assert(!handoff.ShouldHandoff(snapshot, true, 0, true, now));
  assert(!handoff.ShouldHandoff(snapshot, false, 5000, true, now));
  assert(!handoff.ShouldHandoff(snapshot, false, 0, true, now));
  assert(!handoff.ShouldHandoff(snapshot, false, 0, true,
                                now + std::chrono::milliseconds(149)));
  assert(handoff.ShouldHandoff(snapshot, false, 0, true,
                               now + std::chrono::milliseconds(150)));
  assert(!handoff.ShouldHandoff(snapshot, false, 0, true,
                                now + std::chrono::seconds(1)));
  snapshot.queued_audio_frames = 1;
  assert(!handoff.ShouldHandoff(snapshot, false, 0, true,
                                now + std::chrono::seconds(2)));
  snapshot.queued_audio_frames = 0;
  assert(!handoff.ShouldHandoff(snapshot, false, 0, true,
                                now + std::chrono::seconds(3)));
  return 0;
}
