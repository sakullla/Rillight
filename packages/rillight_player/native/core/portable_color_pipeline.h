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
              uint8_t* rgba, int stride);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
