#include "../../../macos/rillight_player/Sources/rillight_player/PixelBufferOutput.h"

#include <cassert>

int main() {
  uint8_t rgba[] = {255, 0, 0, 128, 0, 255, 0, 255, 17, 17, 17, 17,
                    0, 0, 255, 64, 255, 255, 255, 255, 17, 17, 17, 17};
  RillightCoreFrame frame{};
  frame.type = RILLIGHT_CORE_VIDEO_RGBA;
  frame.width = frame.height = 2;
  frame.stride = 12;
  frame.data = rgba;
  frame.data_size = sizeof(rgba);
  frame.sar_num = frame.sar_den = 1;
  std::vector<uint8_t> pixels(32, 17);
  assert(rillight_macos::WriteAcceleratedBgra(frame, 2, 2, pixels.data(), 16, pixels.size()));
  assert(pixels[0] == 0 && pixels[2] == 255 && pixels[3] == 128);
  assert(pixels[16] == 255 && pixels[18] == 0 && pixels[19] == 64);
  assert(pixels[8] == 17 && pixels[15] == 17 && pixels[31] == 17);
  for (int rotation = 0; rotation < 4; ++rotation) {
    frame.has_display_matrix = 1;
    frame.display_matrix[0] = rotation == 0 ? 65536 : rotation == 2 ? -65536 : 0;
    frame.display_matrix[1] = rotation == 1 ? 65536 : rotation == 3 ? -65536 : 0;
    pixels.assign(80, 17);
    assert(rillight_macos::WriteAcceleratedBgra(frame, 3, 4, pixels.data(), 20, pixels.size()));
    if (rotation == 0) {
      // Identity rotation is a vImage fit, not the nearest-neighbor reference.
      assert(pixels[2] > 20 && pixels[3] > 20);
      for (int row = 0; row < 4; ++row)
        assert(pixels[row * 20 + 12] == 17 && pixels[row * 20 + 19] == 17);
      continue;
    }
    const auto expected = rillight_macos::Present(frame, 3, 4);
    for (int row = 0; row < 4; ++row) {
      assert(std::memcmp(pixels.data() + row * 20, expected.bgra.data() + row * 12, 12) == 0);
      assert(pixels[row * 20 + 12] == 17 && pixels[row * 20 + 19] == 17);
    }
  }
  frame.has_display_matrix = 0;
  frame.sar_num = 2;
  pixels.assign(32, 17);
  assert(rillight_macos::WriteAcceleratedBgra(frame, 4, 2, pixels.data(), 16, pixels.size()));
  assert(pixels[2] > 80 && pixels[3] > 80);
  bool colored = false;
  for (size_t index = 0; index + 3 < pixels.size(); index += 4) {
    assert(pixels[index + 3] > 0);
    if (pixels[index] > 80 || pixels[index + 1] > 80 || pixels[index + 2] > 80)
      colored = true;
  }
  assert(colored);
  assert(!rillight_macos::WriteAcceleratedBgra(frame, 2, 2, nullptr, 16, 32));
  assert(!rillight_macos::WriteAcceleratedBgra(frame, 2, 2, pixels.data(), 7, 32));
  assert(!rillight_macos::WriteAcceleratedBgra(frame, 2, 2, pixels.data(), 16, 31));
  frame.data_size = 1;
  assert(!rillight_macos::WriteAcceleratedBgra(frame, 2, 2, pixels.data(), 16, 32));
  return 0;
}
