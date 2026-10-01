#pragma once

#include <flutter/texture_registrar.h>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "audio_output.h"
#include "core_api.h"
#include "gpu_present.h"
#include "hdr_host.h"

class VideoSurface : public std::enable_shared_from_this<VideoSurface> {
 public:
  VideoSurface(RillightCore* core, std::shared_ptr<CoreApi> api,
               flutter::TextureRegistrar* textures, IDXGIAdapter* adapter = nullptr,
               HWND window = nullptr);
  ~VideoSurface();
  void Start(std::function<void(std::string)> ready);
  void Resize(int width, int height);
  void Stop(std::function<void()> done);
  int64_t texture_id() const { return texture_id_; }
  int64_t frames() const { return frames_; }
  int64_t acquired_frames() const { return acquired_frames_; }
  int64_t texture_callbacks() const { return texture_callbacks_; }
  uint64_t acquired_timeline() const { return acquired_timeline_; }
  std::string error() const;
  std::string audio_warning() const;
  bool native_overlay_available() const { return hdr_host_ != nullptr; }
  void ActivateNativeOverlay();
  void UpdateNativeOverlay();
  void HideNativeOverlay();
  rillight_windows::HdrDisplayInfo hdr_display() const;
  uint64_t hdr_source_frames() const;
  rillight_windows::HdrPresentStats hdr_stats() const;

 private:
  struct Frame {
    std::vector<uint8_t> rgba;
    std::shared_ptr<rillight_windows::GpuPixelFrame> gpu;
    int width = 0;
    int height = 0;
    uint64_t session = 0;
    uint64_t timeline = 0;
    uint64_t sequence = 0;
    int64_t pts_us = -1;
    bool decoded = false;
  };
  struct Ticket {
    std::shared_ptr<Frame> frame;
    std::shared_ptr<std::atomic<int>> count;
    FlutterDesktopPixelBuffer descriptor{};
  };
  const FlutterDesktopPixelBuffer* Obtain();
  const FlutterDesktopGpuSurfaceDescriptor* ObtainGpu();
  void Run(std::function<void(std::string)> ready);
  void Initialize();
  bool Publish(const RillightCoreFrame& source, int width, int height,
               uint64_t session, uint64_t timeline, bool decoded = true);
  void SetError(std::string error);

  RillightCore* core_;
  std::shared_ptr<CoreApi> api_;
  flutter::TextureRegistrar* textures_;
  std::unique_ptr<flutter::TextureVariant> texture_;
  int64_t texture_id_ = -1;
  std::thread worker_;
  std::unique_ptr<AudioOutput> audio_;
  mutable std::mutex mutex_;
  std::atomic<bool> stopped_{false};
  bool stop_started_ = false;
  std::vector<std::function<void()>> stop_callbacks_;
  int requested_width_ = 1280;
  int requested_height_ = 720;
  std::string error_;
  std::shared_ptr<Frame> latest_;
  std::deque<std::shared_ptr<Frame>> presentation_;
  std::chrono::steady_clock::time_point notified_at_;
  std::shared_ptr<std::atomic<int>> tickets_ =
      std::make_shared<std::atomic<int>>(0);
  std::atomic<int64_t> frames_{0};
  std::atomic<int64_t> acquired_frames_{0};
  std::atomic<int64_t> texture_callbacks_{0};
  std::atomic<uint64_t> acquired_timeline_{0};
  uint64_t acquired_sequence_ = 0;
  std::unique_ptr<rillight_windows::GpuPresenter> gpu_presenter_;
  std::unique_ptr<rillight_windows::HdrHost> hdr_host_;
  FlutterDesktopGpuSurfaceDescriptor gpu_descriptor_{};
};
