#pragma once
#include <memory>
struct AVFrame;
// Returns an owned IOSurface-backed CVPixelBuffer. Video planes are imported
// with CVMetalTextureCache; CPU code never maps or reads the image payload.
// Failure leaves the existing mapped/portable conversion available.
class MacosTexturePipeline {
 public:
  MacosTexturePipeline();
  ~MacosTexturePipeline();
  std::shared_ptr<void> Render(const AVFrame*, int width, int height, bool dovi,
                               bool linear);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
