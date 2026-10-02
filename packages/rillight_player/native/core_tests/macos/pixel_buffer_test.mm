#include "../../../macos/rillight_player/Sources/rillight_player/PixelBufferOutput.h"

#include <array>
#include <cassert>
#include <cstdio>
#include <vector>

int main() {
  @autoreleasepool {
    std::array<uint8_t, 16> rgba{255, 0, 0, 255, 0, 255, 0, 255,
                                0, 0, 255, 255, 255, 255, 255, 255};
    RillightCoreFrame frame{};
    frame.type = RILLIGHT_CORE_VIDEO_RGBA;
    frame.width = frame.height = 2;
    frame.stride = 8;
    frame.data = rgba.data();
    frame.data_size = rgba.size();
    frame.sar_num = frame.sar_den = 1;
    rillight_macos::PixelBufferOutput output;
    std::array<CVPixelBufferRef, 6> buffers{};
    for (auto& buffer : buffers) {
      const CVReturn status = output.Render(frame, 2, 2, &buffer);
      if (status != kCVReturnSuccess) {
        std::fprintf(stderr, "PixelBufferOutput::Render failed: %d\n", status);
      }
      assert(status == kCVReturnSuccess);
      assert(buffer && CVPixelBufferGetIOSurface(buffer));
      assert(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA);
      CFTypeRef colorSpace = CVBufferCopyAttachment(
          buffer, kCVImageBufferCGColorSpaceKey, nullptr);
      assert(colorSpace);
      CFRelease(colorSpace);
    }
    for (size_t index = 1; index < buffers.size(); ++index) {
      assert(CVPixelBufferGetIOSurface(buffers[0]) != CVPixelBufferGetIOSurface(buffers[index]));
    }
    assert(CVPixelBufferLockBaseAddress(buffers[0], kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess);
    const auto* original = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(buffers[0]));
    assert(original[0] == 0 && original[2] == 255 && original[3] == 255);
    CVPixelBufferRelease(buffers[1]);
    buffers[1] = nullptr;
    rgba[0] = 0;
    rgba[2] = 255;
    rgba[3] = 128;
    assert(output.Render(frame, 2, 2, &buffers[1]) == kCVReturnSuccess);
    assert(CVPixelBufferLockBaseAddress(buffers[1], kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess);
    const auto* changed = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(buffers[1]));
    assert(changed[0] == 255 && changed[2] == 0 && changed[3] == 128);
    CVPixelBufferUnlockBaseAddress(buffers[1], kCVPixelBufferLock_ReadOnly);
    assert(original[0] == 0 && original[2] == 255);
    CVPixelBufferUnlockBaseAddress(buffers[0], kCVPixelBufferLock_ReadOnly);
    for (auto buffer : buffers) CVPixelBufferRelease(buffer);
    frame.has_display_matrix = 1;
    frame.display_matrix[1] = 65536;
    CVPixelBufferRef rotated = nullptr;
    assert(output.Render(frame, 3, 4, &rotated) == kCVReturnSuccess);
    const auto expected = rillight_macos::Present(frame, 3, 4);
    assert(CVPixelBufferLockBaseAddress(rotated, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess);
    const auto* pixels = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(rotated));
    const size_t stride = CVPixelBufferGetBytesPerRow(rotated);
    for (int row = 0; row < 4; ++row) {
      assert(std::memcmp(pixels + row * stride, expected.bgra.data() + row * 12, 12) == 0);
    }
    CVPixelBufferUnlockBaseAddress(rotated, kCVPixelBufferLock_ReadOnly);
    assert(CVPixelBufferGetWidth(rotated) == 3);
    CVPixelBufferRelease(rotated);
    std::vector<uint8_t> hd(8 * 4 * 4, 0);
    RillightCoreFrame large{};
    large.type = RILLIGHT_CORE_VIDEO_RGBA;
    large.width = 8;
    large.height = 4;
    large.stride = 32;
    large.data = hd.data();
    large.data_size = hd.size();
    large.sar_num = large.sar_den = 1;
    rillight_macos::PixelBufferOutput fitted;
    CVPixelBufferRef windowed = nullptr;
    assert(fitted.Render(large, 4, 2, &windowed) == kCVReturnSuccess);
    assert(CVPixelBufferGetWidth(windowed) == 4);
    assert(CVPixelBufferGetHeight(windowed) == 2);
    CVPixelBufferRelease(windowed);
    CVPixelBufferRef retina = nullptr;
    assert(fitted.Render(large, 16, 8, &retina) == kCVReturnSuccess);
    assert(CVPixelBufferGetWidth(retina) == 8);
    assert(CVPixelBufferGetHeight(retina) == 4);
    CVPixelBufferRelease(retina);
    frame.data_size = 1;
    CVPixelBufferRef blocked = nullptr;
    assert(output.Render(frame, 2, 2, &blocked) == kCVReturnInvalidArgument);
    assert(!blocked);
    assert(output.Render(frame, 2, 2, nullptr) == kCVReturnInvalidArgument);
  }
  return 0;
}
