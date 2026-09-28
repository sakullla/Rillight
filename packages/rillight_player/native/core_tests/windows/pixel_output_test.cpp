#include <cassert>
#include <cstdint>

#include "../../../windows/pixel_present.h"

int main() {
  uint8_t pixels[] = {255, 0, 0, 255, 0, 0, 255, 255};
  RillightCoreFrame source{};
  source.struct_size = sizeof(source);
  source.type = RILLIGHT_CORE_VIDEO_RGBA;
  source.width = 2;
  source.height = 1;
  source.stride = 8;
  source.data_size = 8;
  source.data = pixels;
  source.sar_num = 1;
  source.sar_den = 1;
  auto output = rillight_windows::Present(source, 2, 1);
  assert(output.width == 2 && output.height == 1);
  assert(output.rgba[0] == 255 && output.rgba[1] == 0 &&
         output.rgba[2] == 0 && output.rgba[3] == 255);
  assert(output.rgba[4] == 0 && output.rgba[5] == 0 &&
         output.rgba[6] == 255 && output.rgba[7] == 255);

  source.has_display_matrix = 1;
  source.display_matrix[0] = 0;
  source.display_matrix[1] = 65536;
  output = rillight_windows::Present(source, 1, 2);
  assert(output.width == 1 && output.height == 2);
  assert(output.rgba[0] == 255 && output.rgba[2] == 0);
  assert(output.rgba[4 + 0] == 0 && output.rgba[4 + 2] == 255);

  source.has_display_matrix = 0;
  source.sar_num = 2;
  output = rillight_windows::Present(source, 4, 2);
  assert(output.width == 4 && output.height == 2);
  assert(output.rgba[3] == 255);
  assert(output.rgba[(1 * 4 + 3) * 4 + 3] == 255);

  source.stride = 7;
  output = rillight_windows::Present(source, 4, 2);
  assert(output.width == 1 && output.height == 1);
  assert(output.rgba[0] == 0 && output.rgba[3] == 255);

  // Distinct pixels with padded rows catch transposed/rotated lookup offsets,
  // channel swaps and accidental copies from row padding.
  uint8_t grid[32]{};
  for (int y = 0; y < 2; ++y) {
    for (int x = 0; x < 3; ++x) {
      const uint8_t value = static_cast<uint8_t>(y * 3 + x + 1);
      auto* pixel = grid + y * 16 + x * 4;
      pixel[0] = value;
      pixel[1] = value + 10;
      pixel[2] = value + 20;
      pixel[3] = value + 100;
    }
  }
  source.width = 3;
  source.height = 2;
  source.stride = 16;
  source.data_size = sizeof(grid);
  source.data = grid;
  source.sar_num = source.sar_den = 1;
  source.has_display_matrix = 1;
  const int matrices[4][2] = {{65536, 0}, {0, 65536},
                             {-65536, 0}, {0, -65536}};
  const uint8_t expected[4][6] = {{1, 2, 3, 4, 5, 6}, {4, 1, 5, 2, 6, 3},
                                 {6, 5, 4, 3, 2, 1}, {3, 6, 2, 5, 1, 4}};
  for (int rotation = 0; rotation < 4; ++rotation) {
    source.display_matrix[0] = matrices[rotation][0];
    source.display_matrix[1] = matrices[rotation][1];
    output = rillight_windows::Present(source, rotation % 2 ? 2 : 3,
                                        rotation % 2 ? 3 : 2);
    for (int pixel = 0; pixel < 6; ++pixel) {
      const auto value = expected[rotation][pixel];
      assert(output.rgba[pixel * 4] == value);
      assert(output.rgba[pixel * 4 + 1] == value + 10);
      assert(output.rgba[pixel * 4 + 2] == value + 20);
      assert(output.rgba[pixel * 4 + 3] == value + 100);
    }
  }
  source.has_display_matrix = 0;
  output = rillight_windows::Present(source, 6, 6);
  for (int x = 0; x < 6; ++x) {
    assert(output.rgba[x * 4 + 2] == 0 && output.rgba[x * 4 + 3] == 255);
    assert(output.rgba[(5 * 6 + x) * 4 + 2] == 0);
  }
  assert(output.rgba[(1 * 6 + 0) * 4] == 1);
  assert(output.rgba[(2 * 6 + 1) * 4] == 1);
  assert(output.rgba[(4 * 6 + 5) * 4] == 6);
  output = rillight_windows::Present(source, 1, 1);
  assert(output.rgba[0] == 5);
}
