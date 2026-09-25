#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include "../native/core/rillight_core.h"

namespace rillight_windows {

struct PixelFrame {
  int width = 1;
  int height = 1;
  std::vector<uint8_t> bgra = {0, 0, 0, 255};
};

inline PixelFrame Present(const RillightCoreFrame& source, int requested_width,
                          int requested_height) {
  PixelFrame output;
  if (source.type != RILLIGHT_CORE_VIDEO_RGBA || !source.data ||
      source.width <= 0 || source.height <= 0 || source.width > 8192 ||
      source.height > 8192 || source.stride < source.width * 4 ||
      static_cast<int64_t>(source.stride) * source.height > source.data_size) {
    return output;
  }
  output.width = std::clamp(requested_width, 1, 4096);
  output.height = std::clamp(requested_height, 1, 2304);
  output.bgra.resize(static_cast<size_t>(output.width) * output.height * 4);
  for (size_t index = 3; index < output.bgra.size(); index += 4)
    output.bgra[index] = 255;

  const double sar = source.sar_num > 0 && source.sar_den > 0
                         ? std::clamp(static_cast<double>(source.sar_num) /
                                          source.sar_den, 0.1, 10.0)
                         : 1.0;
  int rotation = 0;
  if (source.has_display_matrix) {
    const double a = source.display_matrix[0] / 65536.0;
    const double b = source.display_matrix[1] / 65536.0;
    rotation = static_cast<int>(std::lround(std::atan2(b, a) /
                                            (3.14159265358979323846 / 2.0)));
    rotation = (rotation % 4 + 4) % 4;
  }
  const bool quarter_turn = rotation % 2 != 0;
  const double display_width = quarter_turn ? source.height : source.width * sar;
  const double display_height = quarter_turn ? source.width * sar : source.height;
  const double scale = std::min(output.width / display_width,
                                output.height / display_height);
  const int content_width = std::clamp(
      static_cast<int>(std::lround(display_width * scale)), 1, output.width);
  const int content_height = std::clamp(
      static_cast<int>(std::lround(display_height * scale)), 1, output.height);
  const int left = (output.width - content_width) / 2;
  const int top = (output.height - content_height) / 2;
  for (int y = 0; y < content_height; ++y) {
    for (int x = 0; x < content_width; ++x) {
      const double u = (x + 0.5) / content_width;
      const double v = (y + 0.5) / content_height;
      double source_u = u;
      double source_v = v;
      switch (rotation) {
        case 1: source_u = v; source_v = 1.0 - u; break;
        case 2: source_u = 1.0 - u; source_v = 1.0 - v; break;
        case 3: source_u = 1.0 - v; source_v = u; break;
        default: break;
      }
      const int sx = std::clamp(static_cast<int>(source_u * source.width), 0,
                                source.width - 1);
      const int sy = std::clamp(static_cast<int>(source_v * source.height), 0,
                                source.height - 1);
      const uint8_t* pixel = source.data + static_cast<size_t>(sy) *
                                              source.stride +
                              static_cast<size_t>(sx) * 4;
      const size_t index = (static_cast<size_t>(top + y) * output.width +
                            left + x) * 4;
      output.bgra[index] = pixel[2];
      output.bgra[index + 1] = pixel[1];
      output.bgra[index + 2] = pixel[0];
      output.bgra[index + 3] = pixel[3];
    }
  }
  return output;
}

}  // namespace rillight_windows
