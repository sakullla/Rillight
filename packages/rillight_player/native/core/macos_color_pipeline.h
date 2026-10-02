#pragma once

#include "dovi_color_metadata.h"

#include <cstdint>
#include <memory>

// The owned Metal backend consumes the high-precision planar samples used by
// the portable mapper. It preserves that mapper's transfer LUTs and RPU data.
// A failed device/shader/command leaves the portable CPU path available.
class MacosColorPipeline {
 public:
  MacosColorPipeline();
  ~MacosColorPipeline();
  bool RenderLinearHalf(const AVFrame* sampled,
                        const rillight_color::Constants& constants,
                        int source_depth, bool full_range, bool dolby_vision,
                        int transfer, const float* pq, const float* hlg,
                        uint16_t* output, int stride);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
