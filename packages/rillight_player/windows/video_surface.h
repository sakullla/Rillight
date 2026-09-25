#pragma once

#include <flutter/texture_registrar.h>
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "audio_output.h"
#include "core_api.h"

class VideoSurface : public std::enable_shared_from_this<VideoSurface> {
 public:
  VideoSurface(RillightCore* core, std::shared_ptr<CoreApi> api,
               flutter::TextureRegistrar* textures);
  ~VideoSurface();
  void Start(std::function<void(std::string)> ready);
  void Resize(int width, int height);
  void Stop(std::function<void()> done);
  int64_t texture_id() const { return texture_id_; }
  int64_t frames() const { return frames_; }
  std::string error() const;

 private:
  struct Frame {
    std::vector<uint8_t> rgba;
    int width = 0;
    int height = 0;
  };
  struct Ticket {
    std::shared_ptr<Frame> frame;
    std::shared_ptr<std::atomic<int>> count;
    FlutterDesktopPixelBuffer descriptor{};
  };
  const FlutterDesktopPixelBuffer* Obtain();
  void Run(std::function<void(std::string)> ready);
  void Initialize();
  void Publish(const RillightCoreFrame& source, int width, int height,
               bool decoded = true);
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
  std::shared_ptr<std::atomic<int>> tickets_ =
      std::make_shared<std::atomic<int>>(0);
  std::atomic<int64_t> frames_{0};
};
