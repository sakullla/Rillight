#include "../../../macos/rillight_player/Sources/rillight_player/FrameOutput.h"
#include "../../../macos/rillight_player/Sources/rillight_player/FrameTiming.h"

#include <cassert>
#include <cstdint>

void check_linear_fit() {
  const uint16_t one = rillight_macos::FloatToHalf(1.0f);
  // Include highlights, a negative gamut component and a subnormal. Fitting
  // must preserve their bits, make the canvas opaque and leave row padding.
  uint16_t source[] = {
      rillight_macos::FloatToHalf(4.0f), 0xbc00, 1, 0,
      0x4000, 0x4200, 0x4400, 0,
      0xabcd, 0xabcd, 0xabcd, 0xabcd,
      0x4500, 0x4600, 0x4700, 0,
      0x4800, 0x4880, 0x4900, 0,
      0xabcd, 0xabcd, 0xabcd, 0xabcd};
  RillightCoreFrame frame{};
  frame.type = RILLIGHT_CORE_VIDEO_RGBA16F;
  frame.width = frame.height = 2;
  frame.stride = 24;
  frame.data = reinterpret_cast<uint8_t*>(source);
  frame.data_size = sizeof(source);
  frame.sar_num = frame.sar_den = 1;
  // Row-major source indices after each quarter-turn, independent of the fit.
  const int orders[4][4] = {{0, 1, 2, 3}, {2, 0, 3, 1},
                           {3, 2, 1, 0}, {1, 3, 0, 2}};
  for (int rotation = 0; rotation < 4; ++rotation) {
    frame.has_display_matrix = 1;
    frame.display_matrix[0] = rotation == 0 ? 65536 : rotation == 2 ? -65536 : 0;
    frame.display_matrix[1] = rotation == 1 ? 65536 : rotation == 3 ? -65536 : 0;
    std::vector<uint16_t> fitted(24, 0xabcd);
    assert(rillight_macos::WriteLinearHalf(frame, 2, 2, fitted.data(), 24,
                                           fitted.size() * 2, nullptr));
    for (int i = 0; i < 4; ++i) {
      const int original = orders[rotation][i];
      const auto* src = source + original / 2 * 12 + original % 2 * 4;
      const auto* dst = fitted.data() + i / 2 * 12 + i % 2 * 4;
      assert(std::memcmp(src, dst, 6) == 0 && dst[3] == one);
    }
    assert(fitted[8] == 0xabcd && fitted[23] == 0xabcd);
  }
  frame.has_display_matrix = 0;
  frame.sar_num = 2;
  std::vector<uint16_t> fitted(4 * 4 * 4, 0xabcd);
  assert(rillight_macos::WriteLinearHalf(frame, 4, 4, fitted.data(), 32,
                                         fitted.size() * 2, nullptr));
  for (int x = 0; x < 4; ++x) {
    assert(fitted[x * 4] == 0 && fitted[x * 4 + 3] == one);
    assert(fitted[48 + x * 4] == 0 && fitted[48 + x * 4 + 3] == one);
  }
  assert(fitted[16] == source[0] && fitted[20] == source[0]);
  assert(fitted[24] == source[4] && fitted[32] == source[12]);
  frame.sar_num = 1;
  uint8_t subtitle[] = {255, 255, 255, 128};
  RillightCoreSubtitleOverlay overlay{};
  overlay.x = overlay.y = 1;
  overlay.width = overlay.height = 1;
  overlay.stride = 4;
  overlay.data = subtitle;
  fitted.assign(16, 0xabcd);
  assert(rillight_macos::WriteLinearHalf(frame, 2, 2, fitted.data(), 16,
                                         fitted.size() * 2, &overlay));
  assert(fitted[0] == source[0] && fitted[1] == source[1] && fitted[2] == 1);
  const float alpha = 128 / 255.0f;
  assert(fitted[12] == rillight_macos::FloatToHalf(
      alpha + rillight_macos::HalfToFloat(source[16]) * (1 - alpha)));
  subtitle[3] = 0;
  assert(rillight_macos::WriteLinearHalf(frame, 2, 2, fitted.data(), 16,
                                         fitted.size() * 2, &overlay));
  assert(fitted[12] == source[16]);
  assert(!rillight_macos::WriteLinearHalf(frame, 2, 2, fitted.data(), 15,
                                          fitted.size() * 2, nullptr));
  assert(!rillight_macos::WriteLinearHalf(frame, 2, 2, fitted.data(), 16, 31,
                                          nullptr));
}

int main() {
  check_linear_fit();
  uint8_t rgba[] = {255, 0, 0, 255, 0, 255, 0, 255};
  RillightCoreFrame frame{};
  frame.type = RILLIGHT_CORE_VIDEO_RGBA;
  frame.width = 2;
  frame.height = 1;
  frame.stride = 8;
  frame.data = rgba;
  frame.data_size = sizeof(rgba);
  frame.sar_num = frame.sar_den = 1;

  auto pixels = rillight_macos::Present(frame, 2, 1);
  assert(pixels.width == 2 && pixels.height == 1);
  assert(pixels.bgra[0] == 0 && pixels.bgra[1] == 0 &&
         pixels.bgra[2] == 255 && pixels.bgra[3] == 255);
  assert(pixels.bgra[4] == 0 && pixels.bgra[5] == 255 &&
         pixels.bgra[6] == 0 && pixels.bgra[7] == 255);

  frame.sar_num = 2;
  pixels = rillight_macos::Present(frame, 4, 1);
  assert(pixels.bgra[2] == 255 && pixels.bgra[6] == 255);
  assert(pixels.bgra[10] == 0 && pixels.bgra[13] == 255);

  frame.sar_num = 1;
  frame.has_display_matrix = 1;
  frame.display_matrix[0] = 0;
  frame.display_matrix[1] = 65536;
  pixels = rillight_macos::Present(frame, 1, 2);
  assert(pixels.width == 1 && pixels.height == 2);
  assert(pixels.bgra[2] == 255 && pixels.bgra[5] == 255);

  frame.data_size = 7;
  assert(!rillight_macos::ValidSource(frame));
  frame.data_size = sizeof(rgba);

  const uint16_t one = rillight_macos::FloatToHalf(1.0f);
  const uint16_t bright = rillight_macos::FloatToHalf(4.0f);
  uint16_t half[] = {bright, one, one, one};
  frame.type = RILLIGHT_CORE_VIDEO_RGBA16F;
  frame.width = frame.height = 1;
  frame.stride = 8;
  frame.data = reinterpret_cast<uint8_t*>(half);
  frame.data_size = sizeof(half);
  frame.has_display_matrix = 0;
  frame.sar_num = frame.sar_den = 1;
  uint16_t fitted[4] = {};
  assert(rillight_macos::WriteLinearHalf(frame, 1, 1, fitted, 8, sizeof(fitted),
                                          nullptr));
  assert(rillight_macos::HalfToFloat(fitted[0]) > 2.0f);
  assert(rillight_macos::HalfToFloat(fitted[3]) > 0.9f);
  frame.type = RILLIGHT_CORE_VIDEO_RGBA;
  frame.data = rgba;
  frame.width = 2;
  frame.height = 1;
  frame.stride = 8;
  frame.data_size = sizeof(rgba);
  frame.has_display_matrix = 0;
  std::vector<uint8_t> padded(24, 17);
  assert(rillight_macos::WriteBgra(frame, 2, 2, padded.data(), 12, padded.size()));
  assert(padded[2] == 255 && padded[6] == 0 && padded[7] == 255);
  assert(padded[8] == 17 && padded[11] == 17);
  assert(padded[12] == 0 && padded[15] == 255 && padded[20] == 17);
  assert(!rillight_macos::WriteBgra(frame, 2, 2, padded.data(), 7, padded.size()));
  assert(!rillight_macos::WriteBgra(frame, 2, 2, padded.data(), 12, 23));
  assert(!rillight_macos::WriteBgra(frame, 2, 2, nullptr, 12, padded.size()));
  assert(!rillight_macos::WriteBgra(frame, 2, 2, padded.data(),
                                  std::numeric_limits<size_t>::max(), padded.size()));
  uint8_t strided[] = {255, 0, 0, 128, 0, 255, 0, 255, 17, 17, 17, 17,
                       0, 0, 255, 64, 255, 255, 255, 255, 17, 17, 17, 17};
  frame.data = strided;
  frame.data_size = sizeof(strided);
  frame.height = 2;
  frame.stride = 12;
  padded.assign(24, 17);
  assert(rillight_macos::WriteBgra(frame, 2, 2, padded.data(), 12, padded.size()));
  assert(padded[2] == 255 && padded[3] == 128 && padded[8] == 17);
  assert(padded[12] == 255 && padded[14] == 0 && padded[15] == 64);
  frame.width = 8193;
  assert(!rillight_macos::ValidSource(frame));

  RillightCoreSnapshot snapshot{};
  snapshot.state = RILLIGHT_CORE_PLAYING;
  frame.pts_us = 100000;
  snapshot.position_us = 0;
  assert(!rillight_macos::VideoDue(frame, snapshot));
  snapshot.position_us = 90000;
  assert(rillight_macos::VideoDue(frame, snapshot));
  assert(!rillight_macos::VideoTooLate(frame, snapshot));
  snapshot.position_us = 400000;
  assert(rillight_macos::VideoTooLate(frame, snapshot));
  snapshot.state = RILLIGHT_CORE_READY;
  snapshot.position_us = 0;
  assert(rillight_macos::VideoDue(frame, snapshot));
  snapshot.state = RILLIGHT_CORE_PAUSED;
  frame.pts_us = 750000;
  assert(rillight_macos::VideoDue(frame, snapshot));
  snapshot.state = RILLIGHT_CORE_PLAYING;
  frame.pts_us = 16667;
  assert(!rillight_macos::VideoDue(frame, snapshot));
  snapshot.position_us = 10000;
  assert(rillight_macos::VideoDue(frame, snapshot));
  return 0;
}
