#include "../../../linux/pulse_output.h"

#include <cassert>
#include <chrono>
#include <cstdint>
#include <thread>
#include <vector>

int main() {
  rillight_linux::PulseOutput output;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(5);
  while (output.Latency() < 0 &&
         std::chrono::steady_clock::now() < deadline) {
    assert(output.Pump());
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  // This requires a real PulseAudio server. It catches the NODATA state that
  // remained permanent without AUTO_TIMING_UPDATE / an initial timing request.
  assert(output.Latency() >= 0);
  std::vector<uint8_t> pcm(48000 / 5 * 4, 0);
  size_t offset = 0;
  while (offset < pcm.size() &&
         std::chrono::steady_clock::now() < deadline) {
    assert(output.Pump());
    offset += output.Write(pcm.data() + offset, pcm.size() - offset);
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  assert(offset == pcm.size());
  assert(output.Latency() >= 0);
  const auto drained_deadline = std::chrono::steady_clock::now() +
                                std::chrono::seconds(2);
  while (output.Latency() > 1000 &&
         std::chrono::steady_clock::now() < drained_deadline) {
    assert(output.Pump());
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  // The handoff path waits for device latency to fall below 1 ms. Verify the
  // real stream can reach that condition after its last PCM write.
  assert(output.Latency() >= 0 && output.Latency() <= 1000);
  output.Flush();
  const auto flush_deadline = std::chrono::steady_clock::now() +
                              std::chrono::seconds(5);
  while (output.Latency() < 0 &&
         std::chrono::steady_clock::now() < flush_deadline) {
    assert(output.Pump());
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  assert(output.Latency() >= 0);
  return 0;
}
