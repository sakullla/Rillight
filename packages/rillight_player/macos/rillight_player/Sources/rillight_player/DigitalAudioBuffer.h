#pragma once

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <vector>

namespace rillight_macos {
// One producer (audio queue), one consumer (HAL). No allocation or locks in
// the device callback. Reset is allowed only after AudioDeviceStop completes.
class DigitalAudioBuffer {
 public:
  explicit DigitalAudioBuffer(size_t capacity = 1024 * 1024) : bytes_(capacity) {}
  bool Push(const uint8_t* data, size_t size, bool swap_words = false) {
    const auto write = write_.load(std::memory_order_relaxed);
    const auto read = read_.load(std::memory_order_acquire);
    if (!data || (size & 1) || size > bytes_.size() - (write - read)) return false;
    for (size_t i = 0; i < size; ++i)
      bytes_[(write + i) % bytes_.size()] = data[swap_words ? (i ^ 1) : i];
    write_.store(write + size, std::memory_order_release);
    return true;
  }
  size_t Read(uint8_t* out, size_t size) {
    const auto read = read_.load(std::memory_order_relaxed);
    const auto write = write_.load(std::memory_order_acquire);
    const size_t count = std::min<size_t>(size, write - read);
    const size_t start = read % bytes_.size();
    const size_t first = std::min(count, bytes_.size() - start);
    if (first) std::memcpy(out, bytes_.data() + start, first);
    if (count > first) std::memcpy(out + first, bytes_.data(), count - first);
    if (size > count) std::memset(out + count, 0, size - count);
    read_.store(read + count, std::memory_order_release);
    return count;
  }
  size_t pending() const {
    const auto read = read_.load(std::memory_order_acquire);
    return static_cast<size_t>(write_.load(std::memory_order_acquire) - read);
  }
  void Reset() { read_.store(0); write_.store(0); }
 private:
  std::vector<uint8_t> bytes_;
  std::atomic<uint64_t> read_{0}, write_{0};
};
}  // namespace rillight_macos
