#pragma once

#include <Windows.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <atomic>
#include <memory>
#include "gpu_present.h"

namespace rillight_windows {
struct HdrDisplayInfo {
  bool active = false;
  float sdr_white_nits = 203;
  float peak_nits = 0;
};
struct HdrPresentStats {
  bool valid = false;
  uint32_t present_count = 0, present_refresh = 0, sync_refresh = 0;
  int64_t sync_qpc = 0, qpc_frequency = 0;
};

HdrDisplayInfo QueryHdrDisplay(HWND window, ID3D11Device* device);

// The transparent Flutter window stays above this separate native window.
// A DComp visual below a Flutter child HWND would be clipped by that child.
// DWM composes the SDR controls and native linear HDR independently instead.
class HdrHost {
 public:
  HdrHost(HWND flutter_window, GpuPresenter* presenter);
  ~HdrHost();
  void Activate(); // UI thread, after Flutter has painted transparent content.
  void UpdateWindow(); // UI thread; preserves focus and the parent's z-order.
  void Hide();
  void Draw(const RillightCoreFrame& source, void* texture,
            const RillightCoreSubtitleOverlay* overlay, int width, int height);
  void Commit(); // Video thread; Draw and Commit use one immediate context.
  bool active() const { return active_; }
  HdrDisplayInfo display() const;
  HdrPresentStats stats() const;
  uint64_t hdr_source_frames() const { return hdr_source_frames_; }
  uint64_t presented_frames() const { return presented_frames_; }
 private:
  HWND parent_ = nullptr;
  HWND window_ = nullptr;
  GpuPresenter* presenter_;
  Microsoft::WRL::ComPtr<IDXGISwapChain1> chain_;
  int width_ = 0, height_ = 0;
  std::atomic<bool> active_{false};
  std::atomic<float> sdr_white_nits_{203};
  std::atomic<uint64_t> hdr_source_frames_{0};
  std::atomic<uint64_t> presented_frames_{0};
};
} // namespace rillight_windows
