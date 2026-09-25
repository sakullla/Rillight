#pragma once

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include "core_api.h"

class AudioOutput {
 public:
  AudioOutput(RillightCore* core, std::shared_ptr<CoreApi> api);
  ~AudioOutput();
  void Start();
  void Stop();
  bool Empty() const;
  std::string error() const;

 private:
  void Run();
  RillightCore* core_;
  std::shared_ptr<CoreApi> api_;
  std::atomic<bool> stopped_{false};
  std::atomic<bool> pending_{false};
  std::atomic<uint32_t> device_padding_{0};
  std::thread worker_;
  mutable std::mutex mutex_;
  std::string error_;
};
