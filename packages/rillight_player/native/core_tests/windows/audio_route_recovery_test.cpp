#include "../../../windows/audio_route.h"

#include <cassert>
#include <chrono>
#include <initializer_list>

int main() {
  using rillight_windows::AudioRouteRecovery;
  using namespace std::chrono_literals;
  AudioRouteRecovery recovery;
  const auto start = AudioRouteRecovery::Clock::time_point{};
  // First open has no endpoint yet. No endpoint notification is required.
  assert(recovery.ShouldProbe(1, false, start));
  assert(!recovery.ShouldProbe(1, false, start + 499ms));
  assert(recovery.ShouldProbe(1, false, start + 500ms));
  // The device is still initializing when its single notification arrives.
  assert(recovery.ShouldProbe(2, false, start + 510ms));
  assert(!recovery.ShouldProbe(2, false, start + 1000ms));
  assert(recovery.ShouldProbe(2, false, start + 1010ms));
  // Recovery without another event stops polling once the endpoint is live.
  assert(!recovery.ShouldProbe(2, true, start + 10s));
  // A later output switch always probes immediately, even within the throttle.
  assert(recovery.ShouldProbe(3, true, start + 10s));
  assert(!recovery.ShouldProbe(3, false, start + 10499ms));
  assert(recovery.ShouldProbe(3, false, start + 10500ms));
  // Services/resources may disappear during Bluetooth/HDMI route changes.
  for (const auto hr : {0x88890004u, 0x8889000fu, 0x88890010u, 0x88890026u}) {
    assert(rillight_windows::ClassifyClientFault(static_cast<int32_t>(hr)) ==
           rillight_windows::ClientFault::kLost);
  }
  assert(rillight_windows::ClassifyClientFault(static_cast<int32_t>(0x80004005u)) ==
         rillight_windows::ClientFault::kFatal);
}
