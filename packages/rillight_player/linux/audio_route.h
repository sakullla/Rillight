#pragma once

#include <string>
#include "../native/core/audio_contract.h"

namespace rillight_linux {
struct AudioRoutePolicy {
  std::string name;
  int channels = 2;
  uint32_t advertised = 0;
  uint32_t rejected = 0;

  void Observe(const std::string& next, int count, uint32_t formats) {
    // Volume/stream notifications on the same device must not undo fallback.
    if (!name.empty() && (name != next || advertised != formats)) rejected = 0;
    name = next;
    channels = count;
    advertised = formats;
  }
  void Reject(int kind) {
    const auto bit = rillight_passthrough_accept_bit(kind);
    rejected |= bit ? bit : advertised;
  }
  uint32_t accepted() const { return advertised & ~rejected; }
};
}  // namespace rillight_linux
