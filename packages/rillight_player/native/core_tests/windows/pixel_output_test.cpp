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
  assert(output.bgra[0] == 0 && output.bgra[1] == 0 &&
         output.bgra[2] == 255 && output.bgra[3] == 255);
  assert(output.bgra[4] == 255 && output.bgra[5] == 0 &&
         output.bgra[6] == 0 && output.bgra[7] == 255);

  source.has_display_matrix = 1;
  source.display_matrix[0] = 0;
  source.display_matrix[1] = 65536;
  output = rillight_windows::Present(source, 1, 2);
  assert(output.width == 1 && output.height == 2);
  assert(output.bgra[0] == 0 && output.bgra[2] == 255);
  assert(output.bgra[4 + 0] == 255 && output.bgra[4 + 2] == 0);

  source.has_display_matrix = 0;
  source.sar_num = 2;
  output = rillight_windows::Present(source, 4, 2);
  assert(output.width == 4 && output.height == 2);
  assert(output.bgra[3] == 255);
  assert(output.bgra[(1 * 4 + 3) * 4 + 3] == 255);

  source.stride = 7;
  output = rillight_windows::Present(source, 4, 2);
  assert(output.width == 1 && output.height == 1);
  assert(output.bgra[0] == 0 && output.bgra[3] == 255);
}
