#include "../../../linux/frame_output.h"

#include <cassert>
#include <cstdint>

int main() {
  uint8_t pixels[] = {
      255, 0, 0, 255, 0, 255, 0, 255,
      0, 0, 255, 255, 255, 255, 255, 255,
  };
  RillightCoreFrame source{};
  source.type = RILLIGHT_CORE_VIDEO_RGBA;
  source.width = 2;
  source.height = 2;
  source.stride = 8;
  source.data_size = sizeof(pixels);
  source.data = pixels;
  source.sar_num = 2;
  source.sar_den = 1;
  auto wide = rillight_linux::Present(source, 8, 8);
  assert(wide.width == 8 && wide.height == 8);
  assert(wide.pixels[0] == 0 && wide.pixels[3] == 255);
  assert(wide.pixels[4 * (2 * 8)] == 255);
  assert(wide.pixels[4 * (2 * 8 + 7) + 1] == 255);

  source.has_display_matrix = 1;
  source.display_matrix[0] = 0;
  source.display_matrix[1] = 65536;
  auto rotated = rillight_linux::Present(source, 8, 8);
  assert(rotated.width == 8 && rotated.height == 8);
  assert(rotated.pixels[4 * 2 + 2] == 255);
  assert(rotated.pixels[4 * 5] == 255 &&
         rotated.pixels[4 * 5 + 3] == 255);

  source.stride = 7;
  assert(!rillight_linux::ValidSource(source));
  auto invalid = rillight_linux::Present(source, 8, 8);
  assert(invalid.width == 1 && invalid.height == 1);
  assert(invalid.pixels.size() == 4);
  return 0;
}
