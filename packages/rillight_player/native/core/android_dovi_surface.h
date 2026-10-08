#pragma once

#include <memory>

struct AVFrame;
struct ANativeWindow;
struct AHardwareBuffer;

// A private decoder Surface keeps vendor layouts in gralloc. Byte output can
// advertise NV12 while exposing unusable data for inter-predicted pictures.
class AndroidDoviSurface {
 public:
  static std::shared_ptr<AndroidDoviSurface> Create(int width, int height,
                                                 int time_num, int time_den);
  ~AndroidDoviSurface();
  ANativeWindow* Window() const;
  bool Attach(AVFrame* frame, const std::shared_ptr<AndroidDoviSurface>& owner);
  static AndroidDoviSurface* From(const AVFrame* frame);
  // Caller must finish GPU use of the previous image before acquiring another.
  AHardwareBuffer* Acquire(const AVFrame* frame);

 private:
  AndroidDoviSurface();
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
