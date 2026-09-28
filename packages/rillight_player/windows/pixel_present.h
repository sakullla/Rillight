#pragma once

#include <cstdint>
#include <vector>

#include "../native/core/rillight_core.h"

namespace rillight_windows {

struct PixelFrame {
  int width = 1;
  int height = 1;
  std::vector<uint8_t> rgba = {0, 0, 0, 255};
};

PixelFrame Present(const RillightCoreFrame& source, int requested_width,
                   int requested_height);

}  // namespace rillight_windows
