#include "../../../macos/rillight_player/Sources/rillight_player/DigitalAudioBuffer.h"
#include "../../core/audio_passthrough.h"
#include <cassert>
#include <thread>

int main() {
  const uint32_t accepted = RILLIGHT_CORE_AUDIO_ACCEPT_AC3 | RILLIGHT_CORE_AUDIO_ACCEPT_EAC3;
  assert(rillight_audio_accept_for_gain(accepted, 1.0) == accepted);
  for (double gain : {0.0, 0.5, 0.9999, 1.0001, 1.5})
    assert(rillight_audio_accept_for_gain(accepted, gain) == 0);
  using rillight_macos::DigitalAudioBuffer;
  DigitalAudioBuffer queue(16);
  const uint8_t input[] = {0x72, 0xf8, 0x1f, 0x4e, 0x15, 0, 0x20, 0};
  uint8_t output[16]{};
  assert(queue.Push(input, sizeof(input)));
  assert(queue.Push(input, sizeof(input)));
  assert(!queue.Push(input, sizeof(input)));
  assert(queue.Read(output, 12) == 12);
  assert(queue.Push(input, sizeof(input))); // wraps the physical ring
  assert(queue.Read(output, 16) == 12);
  assert(output[12] == 0 && output[15] == 0);
  assert(queue.pending() == 0);
  assert(queue.Push(input, sizeof(input), true));
  assert(queue.Read(output, 8) == 8);
  for (size_t i = 0; i < 8; ++i) assert(output[i] == input[i ^ 1]);
  queue.Reset();
  assert(queue.pending() == 0);

  DigitalAudioBuffer concurrent(4096);
  std::thread producer([&] {
    for (uint32_t i = 1; i < 20000; ++i) {
      const uint8_t data[] = {uint8_t(i), uint8_t(i >> 8)};
      while (!concurrent.Push(data, 2)) std::this_thread::yield();
    }
  });
  for (uint32_t i = 1; i < 20000; ++i) {
    while (concurrent.pending() < 2) std::this_thread::yield();
    assert(concurrent.Read(output, 2) == 2);
    assert(output[0] == uint8_t(i) && output[1] == uint8_t(i >> 8));
  }
  producer.join();

  const auto eac3 = rillight_audio_carrier(RILLIGHT_CORE_PASSTHROUGH_EAC3, 48000);
  const auto truehd = rillight_audio_carrier(RILLIGHT_CORE_PASSTHROUGH_TRUEHD, 96000);
  assert(eac3.rate == 192000 && eac3.channels == 2);
  assert(truehd.rate == 192000 && truehd.channels == 8);
  assert(rillight_audio_carrier(RILLIGHT_CORE_PASSTHROUGH_TRUEHD, 44100).rate == 176400);
  assert(rillight_audio_carrier(99, 48000).rate == 0);
  uint8_t packet[128] = {0x0b, 0x77, 0, 0, 0x30, 0x80};
  assert(rillight_passthrough_samples(3, packet, 128, 48000) == 1536);
  packet[4] = 0;
  assert(rillight_passthrough_samples(3, packet, 128, 48000) == 256);
  assert(rillight_passthrough_samples(2, packet, 128, 96000) == 80);
  assert(rillight_passthrough_samples(2, packet, 8, 48000) == 0);
  assert(rillight_passthrough_samples(2, packet, 128, 12345) == 0);
  packet[0] = 0x7f; packet[1] = 0xfe; packet[2] = 0x80; packet[3] = 1;
  packet[4] = 0; packet[5] = 0x3c; packet[6] = 7; packet[7] = 0xf0; packet[8] = 0x34;
  assert(rillight_passthrough_samples(5, packet, 128, 48000) == 512);
  assert(rillight_passthrough_samples(6, packet, 128, 96000) == 1024);
  return 0;
}
