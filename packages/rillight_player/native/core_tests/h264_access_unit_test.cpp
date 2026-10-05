#include "../core/h264_access_unit.h"
#include <cassert>
#include <initializer_list>
#include <vector>

int main() {
  auto accepts = [](std::initializer_list<uint8_t> bytes, int length = 4) {
    const std::vector<uint8_t> packet(bytes);
    return rillight_h264_non_picture(packet.data(), packet.size(), length);
  };
  assert(accepts({0, 0, 0, 2, 9, 0xf0})); // AVC AUD only.
  assert(accepts({0, 0, 0, 2, 6, 0x80, 0, 0, 0, 2, 9, 0xf0}));
  assert(accepts({0, 0, 1, 6, 0x80, 0, 0, 0, 1, 9, 0xf0}, 0));
  assert(accepts({2, 7, 0x80, 2, 8, 0x80}, 1));
  assert(!accepts({0, 0, 0, 2, 5, 0x80})); // IDR must never be ignored.
  assert(!accepts({0, 0, 0, 2, 6, 0x80, 0, 0, 0, 2, 1, 0x80}));
  assert(!accepts({0, 0, 1, 6, 0x80, 0, 0, 1, 5, 0x80}, 0));
  assert(!accepts({0, 0, 0, 20, 6, 0x80}));
  assert(!accepts({0, 0, 0, 0}));
  assert(!accepts({0, 0, 0, 1}, 0));
  assert(!accepts({0, 0, 0, 2, 0x86, 0x80}));
  assert(!accepts({0, 0}));
  assert(!accepts({}));
}
