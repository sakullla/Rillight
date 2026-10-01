#pragma once

#include <cstdint>
#include <memory>

struct AVFrame;

// Converts high precision decoded planes at the output size, before any 8-bit
// quantization. The public core frame/texture ownership protocol is unchanged.
class WindowsColorPipeline {
 public:
  WindowsColorPipeline();
  ~WindowsColorPipeline();
  bool Render(const AVFrame* frame, int width, int height, bool dolby_vision,
              uint8_t* rgba, int stride);
  // Owned immutable D3D11 RGBA texture. No CPU readback; the caller releases
  // the returned IUnknown after the platform sink has imported the resource.
  void* RenderTexture(const AVFrame* frame, int width, int height,
                      bool dolby_vision);
  // Native HDR sink only: linear BT.709 scRGB; 1.0 represents 80 nits.
  // Keeps highlights and negative wide-gamut components in immutable FP16.
  // Never pass this texture to Flutter's RGBA8888/BGRA8888 sink.
  void* RenderScRgbTexture(const AVFrame* frame, int width, int height,
                          bool dolby_vision, float sdr_white_nits = 203.0f);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
