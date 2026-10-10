#include "../../../linux/pulse_output.h"

#include <cassert>
#include <chrono>
#include <cstdint>
#include <thread>
#include <vector>

int main() {
  for (const int rate : {44100, 48000, 96000}) {
    auto* format = rillight_linux::PassthroughFormat(RILLIGHT_CORE_PASSTHROUGH_TRUEHD, rate);
    assert(format);
    pa_sample_spec spec{};
    assert(pa_format_info_to_sample_spec(format, &spec, nullptr) == 0);
    assert(spec.channels == 8 && spec.rate == (rate == 44100 ? 176400u : 192000u));
    pa_format_info_free(format);
  }
  auto* eac3 = rillight_linux::PassthroughFormat(RILLIGHT_CORE_PASSTHROUGH_EAC3, 48000);
  pa_sample_spec spec{};
  assert(pa_format_info_to_sample_spec(eac3, &spec, nullptr) == 0);
  assert(spec.channels == 2 && spec.rate == 192000);
  pa_format_info_free(eac3);
  assert(!rillight_linux::PassthroughFormat(99, 48000));
  rillight_linux::PulseOutput output;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(5);
  while (output.Latency() < 0 &&
         std::chrono::steady_clock::now() < deadline) {
    assert(output.Pump());
    output.EnsurePcm(2);
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
