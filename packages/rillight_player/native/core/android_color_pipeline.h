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

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
