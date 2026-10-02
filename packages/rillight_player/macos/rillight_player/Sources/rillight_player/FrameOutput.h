#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

#include "rillight_core.h"

namespace rillight_macos {

struct PixelFrame {
  int width = 1;
  int height = 1;
  std::vector<uint8_t> bgra = {0, 0, 0, 255};
};

inline bool ValidSource(const RillightCoreFrame& frame) {
  return frame.type == RILLIGHT_CORE_VIDEO_RGBA && frame.data &&
         frame.width > 0 && frame.height > 0 &&
         frame.width <= 8192 && frame.height <= 8192 &&
         frame.stride >= frame.width * 4 &&
         static_cast<int64_t>(frame.stride) * frame.height <= frame.data_size;
}

inline bool WriteBgra(const RillightCoreFrame& frame, int requested_width,
                      int requested_height, uint8_t* data, size_t stride,
                      size_t data_size) {
  if (!ValidSource(frame) || !data) return false;
  const int width = std::clamp(requested_width, 1, 4096);
  const int height = std::clamp(requested_height, 1, 2304);
  if (stride < static_cast<size_t>(width) * 4 ||
      stride > std::numeric_limits<size_t>::max() / height ||
      data_size < stride * height) return false;
  const double sar = frame.sar_num > 0 && frame.sar_den > 0
      ? std::clamp(static_cast<double>(frame.sar_num) / frame.sar_den, 0.1, 10.0)
      : 1.0;
  int rotation = 0;
  if (frame.has_display_matrix) {
    const double a = frame.display_matrix[0] / 65536.0;
    const double b = frame.display_matrix[1] / 65536.0;
    rotation = static_cast<int>(std::lround(std::atan2(b, a) /
        (3.14159265358979323846 / 2.0)));
    rotation = (rotation % 4 + 4) % 4;
  }
  const bool quarter_turn = rotation % 2 != 0;
  const double display_width = quarter_turn ? frame.height : frame.width * sar;
  const double display_height = quarter_turn ? frame.width * sar : frame.height;
  const double scale = std::min(width / display_width, height / display_height);
  const int content_width = std::clamp(
      static_cast<int>(std::lround(display_width * scale)), 1, width);
  const int content_height = std::clamp(
      static_cast<int>(std::lround(display_height * scale)), 1, height);
  const int left = (width - content_width) / 2;
  const int top = (height - content_height) / 2;
  if (content_width != width || content_height != height) {
    for (int row = 0; row < height; ++row) {
      uint8_t* target = data + static_cast<size_t>(row) * stride;
      std::memset(target, 0, static_cast<size_t>(width) * 4);
      for (int column = 0; column < width; ++column) target[4 * column + 3] = 255;
    }
  }
  if (rotation == 0 && content_width == frame.width &&
      content_height == frame.height) {
    for (int y = 0; y < content_height; ++y) {
      const uint8_t* source = frame.data + static_cast<size_t>(y) * frame.stride;
      uint8_t* target = data + static_cast<size_t>(top + y) * stride +
                        static_cast<size_t>(left) * 4;
      for (int x = 0; x < content_width; ++x) {
        target[4 * x] = source[4 * x + 2];
        target[4 * x + 1] = source[4 * x + 1];
        target[4 * x + 2] = source[4 * x];
        target[4 * x + 3] = source[4 * x + 3];
      }
    }
    return true;
  }
  for (int y = 0; y < content_height; ++y) {
    for (int x = 0; x < content_width; ++x) {
      const double u = (x + 0.5) / content_width;
      const double v = (y + 0.5) / content_height;
      double source_u = u, source_v = v;
      switch (rotation) {
        case 1: source_u = v; source_v = 1.0 - u; break;
        case 2: source_u = 1.0 - u; source_v = 1.0 - v; break;
        case 3: source_u = 1.0 - v; source_v = u; break;
        default: break;
      }
      const int sx = std::clamp(static_cast<int>(source_u * frame.width),
                                0, frame.width - 1);
      const int sy = std::clamp(static_cast<int>(source_v * frame.height),
                                0, frame.height - 1);
      const uint8_t* src = frame.data + static_cast<size_t>(sy) * frame.stride +
                           static_cast<size_t>(sx) * 4;
      uint8_t* dst = data + static_cast<size_t>(top + y) * stride +
                     static_cast<size_t>(left + x) * 4;
      dst[0] = src[2]; dst[1] = src[1]; dst[2] = src[0]; dst[3] = src[3];
    }
  }
  return true;
}

inline uint16_t FloatToHalf(float value) {
  uint32_t bits = 0;
  std::memcpy(&bits, &value, sizeof(bits));
  const uint32_t sign = (bits >> 16) & 0x8000u;
  int32_t exponent =
      static_cast<int32_t>((bits >> 23) & 0xff) - 127 + 15;
  uint32_t mantissa = bits & 0x7fffffu;
  if (((bits >> 23) & 0xff) == 0xff)
    return static_cast<uint16_t>(sign | 0x7c00u | (mantissa ? 0x200u : 0));
  if (exponent <= 0) {
    if (exponent < -10) return static_cast<uint16_t>(sign);
    mantissa |= 0x800000u;
    const uint32_t shift = static_cast<uint32_t>(1 - exponent);
    uint32_t half = mantissa >> (shift + 13);
    const uint32_t rest = mantissa & ((1u << (shift + 13)) - 1u);
    if (rest > (1u << (shift + 12)) ||
        (rest == (1u << (shift + 12)) && (half & 1u))) ++half;
    return static_cast<uint16_t>(sign | half);
  }
  if (exponent >= 31) return static_cast<uint16_t>(sign | 0x7c00u);
  uint32_t half = mantissa >> 13;
  if ((mantissa & 0x1fffu) > 0x1000u ||
      ((mantissa & 0x1fffu) == 0x1000u && (half & 1u))) {
    ++half;
    if (half == 0x400u) {
      half = 0;
      ++exponent;
      if (exponent >= 31) return static_cast<uint16_t>(sign | 0x7c00u);
    }
  }
  return static_cast<uint16_t>(sign | (static_cast<uint32_t>(exponent) << 10) |
                               half);
}

inline float HalfToFloat(uint16_t half) {
  const uint32_t sign = static_cast<uint32_t>(half & 0x8000u) << 16;
  const uint32_t exponent = (half >> 10) & 0x1fu;
  const uint32_t mantissa = half & 0x3ffu;
  uint32_t bits = 0;
  if (exponent == 0) {
    if (mantissa == 0) bits = sign;
    else {
      uint32_t shifted = mantissa;
      int32_t exp = -14;
      while ((shifted & 0x400u) == 0) { shifted <<= 1; --exp; }
      shifted &= 0x3ffu;
      bits = sign | (static_cast<uint32_t>(exp + 127) << 23) | (shifted << 13);
    }
  } else if (exponent == 31) {
    bits = sign | 0x7f800000u | (mantissa << 13);
  } else {
    bits = sign | ((exponent + 112) << 23) | (mantissa << 13);
  }
  float value = 0;
  std::memcpy(&value, &bits, sizeof(value));
  return value;
}

inline float SrgbToLinear(uint8_t value) {
  const float encoded = value / 255.0f;
  return encoded <= 0.04045f ? encoded / 12.92f
                             : std::pow((encoded + 0.055f) / 1.055f, 2.4f);
}

inline bool ValidLinearSource(const RillightCoreFrame& frame) {
  if (!frame.data || frame.width <= 0 || frame.height <= 0 ||
      frame.width > 8192 || frame.height > 8192) return false;
  if (frame.type == RILLIGHT_CORE_VIDEO_RGBA) return ValidSource(frame);
  if (frame.type != RILLIGHT_CORE_VIDEO_RGBA16F) return false;
  return frame.stride >= frame.width * 8 &&
         static_cast<int64_t>(frame.stride) * frame.height <= frame.data_size;
}

// Fits an 8-bit sRGB or RGBA16F source into tightly packed extended-linear
// RGBA16F. Overlay coordinates are in the source image, before SAR and rotation.
inline bool WriteLinearHalf(const RillightCoreFrame& frame, int requested_width,
                            int requested_height, uint16_t* data, size_t stride,
                            size_t data_size,
                            const RillightCoreSubtitleOverlay* overlay) {
  if (!ValidLinearSource(frame) || !data) return false;
  const int width = std::clamp(requested_width, 1, 4096);
  const int height = std::clamp(requested_height, 1, 2304);
  if (stride < static_cast<size_t>(width) * 8 ||
      stride > std::numeric_limits<size_t>::max() / height ||
      data_size < stride * height) return false;
  const double sar = frame.sar_num > 0 && frame.sar_den > 0
      ? std::clamp(static_cast<double>(frame.sar_num) / frame.sar_den, 0.1, 10.0)
      : 1.0;
  int rotation = 0;
  if (frame.has_display_matrix) {
    const double a = frame.display_matrix[0] / 65536.0;
    const double b = frame.display_matrix[1] / 65536.0;
    rotation = static_cast<int>(std::lround(std::atan2(b, a) /
        (3.14159265358979323846 / 2.0)));
    rotation = (rotation % 4 + 4) % 4;
  }
  const bool quarter_turn = rotation % 2 != 0;
  const double display_width = quarter_turn ? frame.height : frame.width * sar;
  const double display_height = quarter_turn ? frame.width * sar : frame.height;
  const double scale = std::min(width / display_width, height / display_height);
  const int content_width = std::clamp(
      static_cast<int>(std::lround(display_width * scale)), 1, width);
  const int content_height = std::clamp(
      static_cast<int>(std::lround(display_height * scale)), 1, height);
  const int left = (width - content_width) / 2;
  const int top = (height - content_height) / 2;
  const uint16_t opaque = FloatToHalf(1.0f);
  const auto clear_span = [opaque](uint16_t* target, int count) {
    for (int column = 0; column < count; ++column) {
      target[4 * column] = target[4 * column + 1] = target[4 * column + 2] = 0;
      target[4 * column + 3] = opaque;
    }
  };
  for (int row = 0; row < height; ++row) {
    auto* target = reinterpret_cast<uint16_t*>(
        reinterpret_cast<uint8_t*>(data) + static_cast<size_t>(row) * stride);
    if (row < top || row >= top + content_height) {
      clear_span(target, width);
    } else {
      clear_span(target, left);
      clear_span(target + 4 * (left + content_width),
                 width - left - content_width);
    }
  }
  if (frame.type == RILLIGHT_CORE_VIDEO_RGBA16F) {
    // HDR is already extended-linear FP16. Copy its channels unchanged;
    // only subtitle pixels need a float blend. Compute the nearest-neighbor
    // coordinates once per axis instead of dividing for every output pixel.
    thread_local std::vector<int> columns;
    columns.resize(content_width);
    const int column_extent = quarter_turn ? frame.height : frame.width;
    for (int x = 0; x < content_width; ++x) {
      double coordinate = (x + 0.5) / content_width;
      if (rotation == 1 || rotation == 2) coordinate = 1.0 - coordinate;
      columns[x] = std::clamp(static_cast<int>(coordinate * column_extent),
                               0, column_extent - 1);
    }
    const bool has_overlay = overlay && overlay->data && overlay->width > 0 &&
        overlay->height > 0 && overlay->stride >= overlay->width * 4;
    for (int y = 0; y < content_height; ++y) {
      double coordinate = (y + 0.5) / content_height;
      if (rotation == 2 || rotation == 3) coordinate = 1.0 - coordinate;
      const int row_extent = quarter_turn ? frame.width : frame.height;
      const int mapped_row = std::clamp(
          static_cast<int>(coordinate * row_extent), 0, row_extent - 1);
      auto* target = reinterpret_cast<uint16_t*>(
          reinterpret_cast<uint8_t*>(data) +
          static_cast<size_t>(top + y) * stride) + left * 4;
      if (rotation == 0 && content_width == frame.width && !has_overlay) {
        std::memcpy(target, frame.data + static_cast<size_t>(mapped_row) *
                    frame.stride, static_cast<size_t>(content_width) * 8);
        for (int x = 0; x < content_width; ++x) target[x * 4 + 3] = opaque;
        continue;
      }
      for (int x = 0; x < content_width; ++x) {
        const int sx = quarter_turn ? mapped_row : columns[x];
        const int sy = quarter_turn ? columns[x] : mapped_row;
        const auto* source = reinterpret_cast<const uint16_t*>(
            frame.data + static_cast<size_t>(sy) * frame.stride +
            static_cast<size_t>(sx) * 8);
        auto* pixel = target + x * 4;
        std::memcpy(pixel, source, 3 * sizeof(uint16_t));
        pixel[3] = opaque;
        if (!has_overlay || sx < overlay->x || sy < overlay->y ||
            sx >= overlay->x + overlay->width ||
            sy >= overlay->y + overlay->height) continue;
        const uint8_t* subtitle = overlay->data +
            static_cast<size_t>(sy - overlay->y) * overlay->stride +
            static_cast<size_t>(sx - overlay->x) * 4;
        const float alpha = subtitle[3] / 255.0f;
        if (alpha == 0) continue;
        for (int channel = 0; channel < 3; ++channel) {
          pixel[channel] = FloatToHalf(SrgbToLinear(subtitle[channel]) * alpha +
              HalfToFloat(source[channel]) * (1.0f - alpha));
        }
      }
    }
    return true;
  }
  for (int y = 0; y < content_height; ++y) {
    for (int x = 0; x < content_width; ++x) {
      const double u = (x + 0.5) / content_width;
      const double v = (y + 0.5) / content_height;
      double source_u = u, source_v = v;
      switch (rotation) {
        case 1: source_u = v; source_v = 1.0 - u; break;
        case 2: source_u = 1.0 - u; source_v = 1.0 - v; break;
        case 3: source_u = 1.0 - v; source_v = u; break;
        default: break;
      }
      const int sx = std::clamp(static_cast<int>(source_u * frame.width),
                                0, frame.width - 1);
      const int sy = std::clamp(static_cast<int>(source_v * frame.height),
                                0, frame.height - 1);
      const uint8_t* src = frame.data + static_cast<size_t>(sy) * frame.stride +
                           static_cast<size_t>(sx) * 4;
      float red = SrgbToLinear(src[0]);
      float green = SrgbToLinear(src[1]);
      float blue = SrgbToLinear(src[2]);
      if (overlay && overlay->data && sx >= overlay->x && sy >= overlay->y &&
          sx < overlay->x + overlay->width && sy < overlay->y + overlay->height &&
          overlay->stride >= overlay->width * 4) {
        const uint8_t* pixel = overlay->data +
            static_cast<size_t>(sy - overlay->y) * overlay->stride +
            static_cast<size_t>(sx - overlay->x) * 4;
        const float alpha = pixel[3] / 255.0f;
        if (alpha > 0) {
          red = SrgbToLinear(pixel[0]) * alpha + red * (1.0f - alpha);
          green = SrgbToLinear(pixel[1]) * alpha + green * (1.0f - alpha);
          blue = SrgbToLinear(pixel[2]) * alpha + blue * (1.0f - alpha);
        }
      }
      auto* dst = reinterpret_cast<uint16_t*>(
          reinterpret_cast<uint8_t*>(data) +
          static_cast<size_t>(top + y) * stride) + (left + x) * 4;
      dst[0] = FloatToHalf(red);
      dst[1] = FloatToHalf(green);
      dst[2] = FloatToHalf(blue);
      dst[3] = opaque;
    }
  }
  return true;
}

inline PixelFrame Present(const RillightCoreFrame& frame, int requested_width,
                          int requested_height) {
  PixelFrame output;
  if (!ValidSource(frame)) return output;
  output.width = std::clamp(requested_width, 1, 4096);
  output.height = std::clamp(requested_height, 1, 2304);
  const size_t stride = static_cast<size_t>(output.width) * 4;
  output.bgra.resize(stride * output.height);
  WriteBgra(frame, output.width, output.height, output.bgra.data(), stride,
            output.bgra.size());
  return output;
}

}  // namespace rillight_macos
