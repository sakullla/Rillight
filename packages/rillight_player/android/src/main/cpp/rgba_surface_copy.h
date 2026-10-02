#ifndef RILLIGHT_RGBA_SURFACE_COPY_H_
#define RILLIGHT_RGBA_SURFACE_COPY_H_

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

struct RillightRgbaInput {
  const uint8_t* pixels;
  int width;
  int height;
  size_t stride;
};
struct RillightRgbaSurface {
  uint8_t* pixels;
  int width;
  int height;
  size_t stride;
};

inline bool CopyRgbaSurface(const RillightRgbaInput& input,
                            const RillightRgbaSurface& surface) {
  if (!input.pixels || !surface.pixels || input.width <= 0 || input.height <= 0 ||
      surface.width <= 0 || surface.height <= 0 || input.width > 32768 ||
      input.height > 32768 || surface.width > 32768 || surface.height > 32768 ||
      input.stride < static_cast<size_t>(input.width) * 4 ||
      surface.stride < static_cast<size_t>(surface.width) * 4 ||
      static_cast<size_t>(input.height) > std::numeric_limits<size_t>::max() / input.stride ||
      static_cast<size_t>(surface.height) > std::numeric_limits<size_t>::max() / surface.stride)
    return false;
  // SurfaceView can return a buffer at its previous geometry immediately
  // after setBuffersGeometry. Always replace its whole visible extent; the
  // compositor then maps that buffer to the unchanged video display rectangle.
  if (input.width == surface.width && input.height == surface.height) {
    for (int y = 0; y < input.height; ++y)
      std::memcpy(surface.pixels + static_cast<size_t>(y) * surface.stride,
                  input.pixels + static_cast<size_t>(y) * input.stride,
                  static_cast<size_t>(input.width) * 4);
  } else {
    for (int y = 0; y < surface.height; ++y) {
      const size_t source_y = static_cast<size_t>(y) * input.height / surface.height;
      for (int x = 0; x < surface.width; ++x) {
        const size_t source_x = static_cast<size_t>(x) * input.width / surface.width;
        std::memcpy(surface.pixels + static_cast<size_t>(y) * surface.stride + x * 4,
                    input.pixels + source_y * input.stride + source_x * 4, 4);
      }
    }
  }
  return true;
}
#endif
