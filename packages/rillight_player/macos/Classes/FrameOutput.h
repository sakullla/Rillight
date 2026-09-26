#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include "../../native/core/rillight_core.h"

namespace rillight_macos {

struct PixelFrame {
  int width = 1;
  int height = 1;
  std::vector<uint8_t> bgra = {0, 0, 0, 255};
};

inline bool ValidSource(const RillightCoreFrame& frame) {
  return frame.type == RILLIGHT_CORE_VIDEO_RGBA && frame.data &&
         frame.width > 0 && frame.height > 0 &&
         frame.width <= 8192 && frame.height <= 8192 &&
         frame.stride >= frame.width * 4 &&
         static_cast<int64_t>(frame.stride) * frame.height <= frame.data_size;
}

// The core has already converted source range and matrix to full-range RGBA
// and composed subtitles. Flutter receives a new, immutable IOSurface for
// each publication; this helper only adapts orientation, SAR, and viewport.
inline PixelFrame Present(const RillightCoreFrame& frame, int requested_width,
                          int requested_height) {
  PixelFrame output;
  if (!ValidSource(frame)) return output;
  const int width = std::clamp(requested_width, 1, 4096);
  const int height = std::clamp(requested_height, 1, 2304);
  const double sar = frame.sar_num > 0 && frame.sar_den > 0
      ? std::clamp(static_cast<double>(frame.sar_num) / frame.sar_den, 0.1, 10.0)
      : 1.0;
  int rotation = 0;
  if (frame.has_display_matrix) {
    const double a = frame.display_matrix[0] / 65536.0;
    const double b = frame.display_matrix[1] / 65536.0;
    rotation = static_cast<int>(std::lround(std::atan2(b, a) /
        (3.14159265358979323846 / 2.0)));
    rotation = (rotation % 4 + 4) % 4;
  }
  const bool quarter_turn = rotation % 2 != 0;
  const double display_width = quarter_turn ? frame.height : frame.width * sar;
  const double display_height = quarter_turn ? frame.width * sar : frame.height;
  const double scale = std::min(width / display_width, height / display_height);
  const int content_width = std::clamp(
      static_cast<int>(std::lround(display_width * scale)), 1, width);
  const int content_height = std::clamp(
      static_cast<int>(std::lround(display_height * scale)), 1, height);
  const int left = (width - content_width) / 2;
  const int top = (height - content_height) / 2;
  output.width = width;
  output.height = height;
  output.bgra.resize(static_cast<size_t>(width) * height * 4, 0);
  for (size_t i = 3; i < output.bgra.size(); i += 4) output.bgra[i] = 255;
  if (rotation == 0 && width == frame.width && height == frame.height &&
      content_width == width && content_height == height) {
    for (int y = 0; y < height; ++y) {
      const uint8_t* source = frame.data + static_cast<size_t>(y) * frame.stride;
      uint8_t* target = output.bgra.data() + static_cast<size_t>(y) * width * 4;
      for (int x = 0; x < width; ++x) {
        target[4 * x] = source[4 * x + 2];
        target[4 * x + 1] = source[4 * x + 1];
        target[4 * x + 2] = source[4 * x];
        target[4 * x + 3] = source[4 * x + 3];
      }
    }
    return output;
  }
  for (int y = 0; y < content_height; ++y) {
    for (int x = 0; x < content_width; ++x) {
      const double u = (x + 0.5) / content_width;
      const double v = (y + 0.5) / content_height;
      double source_u = u, source_v = v;
      switch (rotation) {
        case 1: source_u = v; source_v = 1.0 - u; break;
        case 2: source_u = 1.0 - u; source_v = 1.0 - v; break;
        case 3: source_u = 1.0 - v; source_v = u; break;
        default: break;
      }
      const int sx = std::clamp(static_cast<int>(source_u * frame.width),
                                0, frame.width - 1);
      const int sy = std::clamp(static_cast<int>(source_v * frame.height),
                                0, frame.height - 1);
      const uint8_t* src = frame.data + static_cast<size_t>(sy) * frame.stride +
                           static_cast<size_t>(sx) * 4;
      uint8_t* dst = output.bgra.data() +
                     (static_cast<size_t>(top + y) * width + left + x) * 4;
      dst[0] = src[2]; dst[1] = src[1]; dst[2] = src[0]; dst[3] = src[3];
    }
  }
  return output;
}

}  // namespace rillight_macos
