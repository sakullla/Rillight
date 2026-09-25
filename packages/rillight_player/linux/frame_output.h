#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

#include "../native/core/rillight_core.h"

namespace rillight_linux {

struct PixelFrame {
  int width = 1;
  int height = 1;
  std::vector<uint8_t> pixels = std::vector<uint8_t>(4, 0);
};

inline bool ValidSource(const RillightCoreFrame& source) {
  return source.type == RILLIGHT_CORE_VIDEO_RGBA && source.data &&
         source.width > 0 && source.height > 0 &&
         source.width <= 8192 && source.height <= 8192 &&
         source.stride >= source.width * 4 &&
         static_cast<int64_t>(source.stride) * source.height <= source.data_size;
}

// FlPixelBufferTexture accepts a completed, tightly packed CPU image. Keep
// this conversion independent of GTK so rotation, SAR and lifetime can be
// checked without a display server. FFmpeg already converts source range and
// matrix to full-range RGBA before this point.
inline PixelFrame Present(const RillightCoreFrame& source, int requested_width,
                          int requested_height) {
  PixelFrame output;
  if (!ValidSource(source)) return output;

  const int viewport_width = std::clamp(requested_width, 1, 4096);
  const int viewport_height = std::clamp(requested_height, 1, 2304);
  const double sar = source.sar_num > 0 && source.sar_den > 0
                         ? std::clamp(static_cast<double>(source.sar_num) /
                                          source.sar_den, 0.1, 10.0)
                         : 1.0;
  int rotation = 0;
  if (source.has_display_matrix) {
    // FFmpeg's matrix uses signed 16.16 entries. Common display matrices are
    // orthogonal rotations; selecting the nearest quadrant also avoids a
    // costly and subtly different affine transform on each output frame.
    const double a = source.display_matrix[0] / 65536.0;
    const double b = source.display_matrix[1] / 65536.0;
    rotation = static_cast<int>(std::lround(std::atan2(b, a) /
                                            (3.14159265358979323846 / 2.0)));
    rotation = (rotation % 4 + 4) % 4;
  }
  const bool quarter_turn = rotation % 2 != 0;
  const double display_width = quarter_turn ? source.height : source.width * sar;
  const double display_height = quarter_turn ? source.width * sar : source.height;
  const double scale = std::min(viewport_width / display_width,
                                viewport_height / display_height);
  const int content_width = std::max(1, std::min(viewport_width,
                          static_cast<int>(std::lround(display_width * scale))));
  const int content_height = std::max(1, std::min(viewport_height,
                           static_cast<int>(std::lround(display_height * scale))));
  output.width = viewport_width;
  output.height = viewport_height;
  output.pixels.resize(static_cast<size_t>(viewport_width) * viewport_height * 4);
  for (size_t i = 3; i < output.pixels.size(); i += 4)
    output.pixels[i] = 255;
  if (rotation == 0 && content_width == source.width &&
      content_height == source.height && viewport_width == source.width &&
      viewport_height == source.height &&
      source.stride == source.width * 4) {
    std::memcpy(output.pixels.data(), source.data, output.pixels.size());
    return output;
  }
  const int left = (viewport_width - content_width) / 2;
  const int top = (viewport_height - content_height) / 2;
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
      const int sx = std::clamp(static_cast<int>(source_u * source.width),
                                0, source.width - 1);
      const int sy = std::clamp(static_cast<int>(source_v * source.height),
                                0, source.height - 1);
      const uint8_t* pixel = source.data + static_cast<size_t>(sy) *
                             source.stride + static_cast<size_t>(sx) * 4;
      const size_t index = (static_cast<size_t>(top + y) * viewport_width +
                            left + x) * 4;
      std::copy_n(pixel, 4, output.pixels.data() + index);
    }
  }
  return output;
}

}  // namespace rillight_linux
