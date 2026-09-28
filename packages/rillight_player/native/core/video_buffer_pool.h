#ifndef RILLIGHT_VIDEO_BUFFER_POOL_H_
#define RILLIGHT_VIDEO_BUFFER_POOL_H_

#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

// Returned frames can outlive the decoder and be released on renderer threads.
// The shared owner retains at most two matching allocations, capped at 64 MiB.
class VideoBufferPool {
 public:
  uint8_t* Acquire(size_t bytes) {
    std::lock_guard lock(mutex_);
    if (bytes != size_) {
      available_.clear();
      size_ = bytes;
    }
    if (available_.empty()) return new (std::nothrow) uint8_t[bytes];
    auto buffer = std::move(available_.back());
    available_.pop_back();
    return buffer.release();
  }

  void Recycle(uint8_t* data, size_t bytes) {
    std::unique_ptr<uint8_t[]> buffer(data);
    std::lock_guard lock(mutex_);
    if (bytes == size_ && available_.size() < 2 &&
        bytes <= (64u * 1024u * 1024u) / (available_.size() + 1)) {
      available_.push_back(std::move(buffer));
    }
  }

  // Drop retained frames when a playback session ends. Outstanding frames
  // still return through Recycle and are freed instead of kept for the next
  // episode.
  void Release() {
    std::lock_guard lock(mutex_);
    available_.clear();
    size_ = 0;
  }

 private:
  std::mutex mutex_;
  size_t size_ = 0;
  std::vector<std::unique_ptr<uint8_t[]>> available_;
};

#endif
