#include "pixel_present.h"

#include <algorithm>
#include <cmath>

namespace rillight_windows {

PixelFrame Present(const RillightCoreFrame& source, int requested_width,
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
  output.rgba.resize(static_cast<size_t>(output.width) * output.height * 4);
  uint8_t* target = output.rgba.data();
  for (size_t index = 3; index < output.rgba.size(); index += 4)
    target[index] = 255;

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
  // Resolve scale/rotation once per row or column. In debug builds, doing
  // divisions, clamp calls and checked vector access for every pixel can make
  // presentation slower than the media clock even when hardware decode is fast.
  std::vector<size_t> columns(content_width);
  std::vector<size_t> rows(content_height);
  const auto coordinate = [](int index, int count, int extent, bool reverse) {
    const double value = (index + 0.5) / count;
    return std::clamp(static_cast<int>((reverse ? 1.0 - value : value) * extent),
                      0, extent - 1);
  };
  for (int x = 0; x < content_width; ++x) {
    columns[x] = static_cast<size_t>(coordinate(
        x, content_width, quarter_turn ? source.height : source.width,
        rotation == 1 || rotation == 2)) * (quarter_turn ? source.stride : 4);
  }
  for (int y = 0; y < content_height; ++y) {
    rows[y] = static_cast<size_t>(coordinate(
        y, content_height, quarter_turn ? source.width : source.height,
        rotation == 2 || rotation == 3)) * (quarter_turn ? 4 : source.stride);
  }
  const size_t* column_offsets = columns.data();
  for (int y = 0; y < content_height; ++y) {
    const uint8_t* row = source.data + rows[y];
    uint8_t* destination = target +
        (static_cast<size_t>(top + y) * output.width + left) * 4;
    for (int x = 0; x < content_width; ++x) {
      const uint8_t* pixel = row + column_offsets[x];
      destination[0] = pixel[0];
      destination[1] = pixel[1];
      destination[2] = pixel[2];
      destination[3] = pixel[3];
      destination += 4;
    }
  }
  return output;
}

}  // namespace rillight_windows
