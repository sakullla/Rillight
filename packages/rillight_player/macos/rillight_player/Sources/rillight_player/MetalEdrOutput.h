#pragma once

#include "FrameOutput.h"

#import <AppKit/AppKit.h>

namespace rillight_macos {

struct EdrSurface {
  NSView* view = nil;
  void* presenter = nullptr;
  double headroom = 1;
  bool ready = false;
};

struct EdrPresentationStats {
  int64_t frames = 0;
  int64_t first_presented_us = 0;
  int64_t last_presented_us = 0;
  int64_t max_interval_us = 0;
};

EdrPresentationStats ReadEdrPresentationStats(const EdrSurface* surface);
void ResetEdrPresentationStats(EdrSurface* surface);

// headroom is 1 when the screen cannot show extended values. Creating the
// layer fails closed: ready stays false and the caller keeps the 8-bit texture.
bool CreateEdrSurface(EdrSurface* surface, NSView* flutter_view, double* headroom);
void DestroyEdrSurface(EdrSurface* surface);
void ActivateEdrSurface(EdrSurface* surface, NSView* flutter_view);
// Presents one fitted linear frame. Returns false without replacing the last
// successful drawable when the layer cannot provide one.
bool PresentEdrSurface(EdrSurface* surface, const uint16_t* pixels, int width,
                       int height, size_t stride);

}  // namespace rillight_macos
