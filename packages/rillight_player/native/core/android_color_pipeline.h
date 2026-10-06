#pragma once

#include <memory>

struct AVFrame;
struct ANativeWindow;

// Owned GLES presentation on the calling output thread. Consumes borrowed
// 10-bit P010 planes and per-frame RPU; no CPU RGBA conversion or readback.
class AndroidColorPipeline {
 public:
  AndroidColorPipeline();
  ~AndroidColorPipeline();
  bool Render(const AVFrame* frame, ANativeWindow* window, bool hdr_supported);
  // True only after a successful BT.2020 PQ surface, never a Dolby HDMI signal.
  bool HdrPresented() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
