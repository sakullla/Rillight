#include "../../../macos/Classes/FrameOutput.h"
#include "../../../macos/Classes/FrameTiming.h"

#include <cassert>
#include <cstdint>

int main() {
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

  RillightCoreSnapshot snapshot{};
  snapshot.state = RILLIGHT_CORE_PLAYING;
  frame.pts_us = 100000;
  snapshot.position_us = 0;
  assert(!rillight_macos::VideoDue(frame, snapshot));
  snapshot.position_us = 70000;
  assert(rillight_macos::VideoDue(frame, snapshot));
  assert(!rillight_macos::VideoTooLate(frame, snapshot));
  snapshot.position_us = 400000;
  assert(rillight_macos::VideoTooLate(frame, snapshot));
  snapshot.state = RILLIGHT_CORE_READY;
  snapshot.position_us = 0;
  assert(rillight_macos::VideoDue(frame, snapshot));
  return 0;
}
