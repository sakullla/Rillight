#pragma once

#include <Accelerate/Accelerate.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#include <IOSurface/IOSurface.h>

#include <cstdint>
#include <vector>

#include "FrameOutput.h"

namespace rillight_macos {

inline int QuarterTurns(const RillightCoreFrame& frame) {
  if (!frame.has_display_matrix) return 0;
  const double a = frame.display_matrix[0] / 65536.0;
  const double b = frame.display_matrix[1] / 65536.0;
  const int rotation = static_cast<int>(std::lround(
      std::atan2(b, a) / (3.14159265358979323846 / 2.0)));
  return (rotation % 4 + 4) % 4;
}

// Flutter Impeller accepts BGRA and 8-bit biplanar YUV only, and its YUV
// wrapper is BT.601. VideoToolbox NV12 stays on this BGRA path. The view is
// the full window in physical pixels, so a matching-size permute is the
// common case only at 1:1. Anything else used to walk every output pixel in
// scalar code; vImage does that fit.
inline bool WriteAcceleratedBgra(const RillightCoreFrame& frame, int width,
                                 int height, uint8_t* data, size_t stride,
                                 size_t data_size) {
  if (!ValidSource(frame) || !data) return false;
  width = std::clamp(width, 1, 4096);
  height = std::clamp(height, 1, 2304);
  if (stride < static_cast<size_t>(width) * 4 ||
      stride > std::numeric_limits<size_t>::max() / height ||
      data_size < stride * height) return false;
  if (QuarterTurns(frame) != 0)
    return WriteBgra(frame, width, height, data, stride, data_size);
  const double sar = frame.sar_num > 0 && frame.sar_den > 0
      ? std::clamp(static_cast<double>(frame.sar_num) / frame.sar_den, 0.1, 10.0)
      : 1.0;
  const double scale = std::min(width / (frame.width * sar),
                                static_cast<double>(height) / frame.height);
  const int content_width = std::clamp(
      static_cast<int>(std::lround(frame.width * sar * scale)), 1, width);
  const int content_height = std::clamp(
      static_cast<int>(std::lround(frame.height * scale)), 1, height);
  const int left = (width - content_width) / 2;
  const int top = (height - content_height) / 2;
  if (content_width != width || content_height != height) {
    auto clear_span = [](uint8_t* row, int count) {
      if (count <= 0) return;
      if (reinterpret_cast<uintptr_t>(row) % 4 == 0) {
        auto* pixels = reinterpret_cast<uint32_t*>(row);
        for (int column = 0; column < count; ++column) pixels[column] = 0xff000000u;
        return;
      }
      std::memset(row, 0, static_cast<size_t>(count) * 4);
      for (int column = 0; column < count; ++column) row[4 * column + 3] = 255;
    };
    for (int row = 0; row < top; ++row)
      clear_span(data + static_cast<size_t>(row) * stride, width);
    for (int row = top + content_height; row < height; ++row)
      clear_span(data + static_cast<size_t>(row) * stride, width);
    if (left > 0 || left + content_width < width) {
      for (int row = top; row < top + content_height; ++row) {
        uint8_t* line = data + static_cast<size_t>(row) * stride;
        clear_span(line, left);
        clear_span(line + static_cast<size_t>(left + content_width) * 4,
                   width - left - content_width);
      }
    }
  }
  const uint8_t channels[] = {2, 1, 0, 3};
  vImage_Buffer source{frame.data, static_cast<vImagePixelCount>(frame.height),
                      static_cast<vImagePixelCount>(frame.width),
                      static_cast<size_t>(frame.stride)};
  vImage_Buffer target{
      data + static_cast<size_t>(top) * stride + static_cast<size_t>(left) * 4,
      static_cast<vImagePixelCount>(content_height),
      static_cast<vImagePixelCount>(content_width), stride};
  if (content_width == frame.width && content_height == frame.height) {
    return vImagePermuteChannels_ARGB8888(&source, &target, channels,
                                         kvImageNoFlags) == kvImageNoError;
  }
  thread_local std::vector<uint8_t> packed;
  thread_local std::vector<uint8_t> scale_temp;
  const size_t packed_bytes =
      static_cast<size_t>(frame.width) * static_cast<size_t>(frame.height) * 4;
  packed.resize(packed_bytes);
  vImage_Buffer swapped{packed.data(), static_cast<vImagePixelCount>(frame.height),
                       static_cast<vImagePixelCount>(frame.width),
                       static_cast<size_t>(frame.width) * 4};
  if (vImagePermuteChannels_ARGB8888(&source, &swapped, channels,
                                    kvImageNoFlags) != kvImageNoError) {
    return WriteBgra(frame, width, height, data, stride, data_size);
  }
  const vImage_Error bytes = vImageScale_ARGB8888(
      &swapped, &target, nullptr, kvImageGetTempBufferSize);
  void* temp = nullptr;
  if (bytes > 0) {
    scale_temp.resize(static_cast<size_t>(bytes));
    temp = scale_temp.data();
  }
  if (vImageScale_ARGB8888(&swapped, &target, temp, kvImageNoFlags) !=
      kvImageNoError) {
    return WriteBgra(frame, width, height, data, stride, data_size);
  }
  return true;
}

class PixelBufferOutput {
 public:
  PixelBufferOutput() = default;
  PixelBufferOutput(const PixelBufferOutput&) = delete;
  PixelBufferOutput& operator=(const PixelBufferOutput&) = delete;
  ~PixelBufferOutput() {
    if (pool_) CFRelease(pool_);
  }

  CVReturn Render(const RillightCoreFrame& frame, int width, int height,
                  CVPixelBufferRef* output) {
    if (!output) return kCVReturnInvalidArgument;
    *output = nullptr;
    if (!ValidSource(frame)) return kCVReturnInvalidArgument;
    width = std::clamp(width, 1, 4096);
    height = std::clamp(height, 1, 2304);
    // The Flutter texture is stretched to the view. Keep the view's aspect
    // ratio, but do not resample square-pixel frames: a larger Retina view
    // used to upscale on the CPU. The GPU samples this smaller buffer.
    if (QuarterTurns(frame) == 0 && height > 0) {
      const double sar = frame.sar_num > 0 && frame.sar_den > 0
          ? std::clamp(static_cast<double>(frame.sar_num) / frame.sar_den,
                      0.1, 10.0)
          : 1.0;
      if (std::abs(sar - 1.0) < 0.001) {
        const int across = std::max(
            1, static_cast<int>(std::lround(frame.height * static_cast<double>(width) / height)));
        const int down = std::max(
            1, static_cast<int>(std::lround(frame.width * static_cast<double>(height) / width)));
        width = std::clamp(std::max(frame.width, across), 1, 4096);
        height = std::clamp(std::max(frame.height, down), 1, 4096);
      }
    }
    CVPixelBufferRef buffer = nullptr;
    const CVReturn allocated = CreateBuffer(width, height, &buffer);
    if (allocated != kCVReturnSuccess) return allocated;
    if (!CVPixelBufferGetIOSurface(buffer)) {
      CVPixelBufferRelease(buffer);
      return kCVReturnInvalidPixelBufferAttributes;
    }
    const CVReturn locked = CVPixelBufferLockBaseAddress(buffer, 0);
    if (locked != kCVReturnSuccess) {
      CVPixelBufferRelease(buffer);
      return locked;
    }
    auto* data = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(buffer));
    const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    const bool rendered = WriteAcceleratedBgra(
        frame, width, height, data, stride, CVPixelBufferGetDataSize(buffer));
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    if (!rendered) {
      CVPixelBufferRelease(buffer);
      return kCVReturnInvalidArgument;
    }
    CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey,
                          ColorSpace(), kCVAttachmentMode_ShouldPropagate);
    *output = buffer;
    return kCVReturnSuccess;
  }

 private:
  CVPixelBufferPoolRef pool_ = nullptr;
  int pool_width_ = 0;
  int pool_height_ = 0;

  // Flutter's Impeller texture keeps the last CVPixelBuffer until the next
  // copyPixelBuffer, and the Metal texture can outlive that release by a
  // frame. The pool will not vend a buffer that still has a retain. Four
  // buffers are kept warm; the allocation threshold above refuses a seventh.
  CVReturn CreateBuffer(int width, int height, CVPixelBufferRef* buffer) {
    if (!pool_ || pool_width_ != width || pool_height_ != height) {
      if (pool_) CFRelease(pool_);
      pool_ = nullptr;
      NSDictionary* pixel = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
      };
      NSDictionary* options = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @4,
      };
      const CVReturn created = CVPixelBufferPoolCreate(
          kCFAllocatorDefault, (__bridge CFDictionaryRef)options,
          (__bridge CFDictionaryRef)pixel, &pool_);
      if (created != kCVReturnSuccess) pool_ = nullptr;
      pool_width_ = width;
      pool_height_ = height;
    }
    if (pool_) {
      // Cap growth at 6. Flutter retains the previous buffer, and the Metal
      // texture can outlive that release by one frame. Past the cap, fall
      // back to a one-off buffer instead of blocking the video queue.
      NSDictionary* aux = @{
        (id)kCVPixelBufferPoolAllocationThresholdKey: @6,
      };
      const CVReturn pooled = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
          kCFAllocatorDefault, pool_, (__bridge CFDictionaryRef)aux, buffer);
      if (pooled == kCVReturnSuccess) return pooled;
    }
    NSDictionary* attributes = @{
      (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
      (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    return CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attributes, buffer);
  }

  static CGColorSpaceRef ColorSpace() {
    static CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    return space;
  }
};

}
