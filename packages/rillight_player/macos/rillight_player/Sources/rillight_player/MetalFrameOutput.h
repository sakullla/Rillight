#pragma once
#import <CoreVideo/CoreVideo.h>

#include <memory>

#include "FrameOutput.h"
namespace rillight_macos {
// All video fitting and subtitle blending occurs on Metal textures. The only
// uploaded CPU pixels are the cropped, immutable subtitle overlay.
CVPixelBufferRef CpuFallbackBuffer(CVPixelBufferRef input,
                                   const RillightCoreFrame& frame, int width,
                                   int height,
                                   const RillightCoreSubtitleOverlay* overlay);
class MetalFrameOutput {
 public:
  MetalFrameOutput();
  ~MetalFrameOutput();
  bool Ready();
  CVPixelBufferRef Render(CVPixelBufferRef input,
                          const RillightCoreFrame& frame, int width, int height,
                          const RillightCoreSubtitleOverlay* overlay);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}  // namespace rillight_macos
