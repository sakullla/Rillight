#pragma once

#include <cstdint>
#include <memory>

struct AVFrame;

// High precision SDR presentation for CPU frames on every platform. It also
// provides a fallback when a platform GPU cannot consume the decoded format.
// HDR display output must use a separately negotiated native presentation path.
class PortableColorPipeline {
 public:
  PortableColorPipeline();
  ~PortableColorPipeline();
  bool Render(const AVFrame* frame, int width, int height, bool dolby_vision,
              uint8_t* rgba, int stride, const AVFrame* enhancement = nullptr);
  // Extended-linear RGBA16F. 1.0 is 203-nit SDR white and highlights are
  // greater than 1.0. This does not tone-map or quantize to 8-bit sRGB.
  // enhancement, when set, is the FEL layer added after RPU reshape.
  bool RenderLinearHalf(const AVFrame* frame, int width, int height,
                        bool dolby_vision, uint16_t* rgba, int stride,
                        const AVFrame* enhancement = nullptr);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
