#include "../../android/src/main/cpp/rgba_surface_copy.h"
#include <array>
#include <cassert>
#include <cstdio>
#include <vector>

int main() {
  // Two small current frames must replace every visible pixel in a buffer
  // retained at the previous session's size, without touching row padding.
  const std::array<uint8_t, 16> image{
      255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255};
  std::vector<uint8_t> output(4 * 20, 99);
  const auto check = [&](const std::array<uint8_t,16>& source) {
    assert(CopyRgbaSurface({source.data(),2,2,8}, {output.data(),4,4,20}));
    for (int y=0; y<4; ++y) {
      for (int x=0; x<4; ++x) for (int c=0; c<4; ++c)
        assert(output[y*20+x*4+c] == source[(y/2*2+x/2)*4+c]);
      for (int p=16; p<20; ++p) assert(output[y*20+p] == 99);
    }
  };
  check(image);
  std::array<uint8_t,16> replacement{}; replacement.fill(17);
  check(replacement);
  std::array<uint8_t,4> small{};
  assert(CopyRgbaSurface({image.data(),2,2,8}, {small.data(),1,1,4}));
  for (int c=0;c<4;++c) assert(small[c] == image[c]);
  std::array<uint8_t,16> exact{};
  assert(CopyRgbaSurface({image.data(),2,2,8}, {exact.data(),2,2,8}));
  assert(exact == image);
  assert(!CopyRgbaSurface({image.data(),2,2,7}, {exact.data(),2,2,8}));
  assert(!CopyRgbaSurface({image.data(),2,2,8}, {exact.data(),0,2,8}));
  std::puts("Full RGBA surface replacement, resize and padding checks passed");
}
