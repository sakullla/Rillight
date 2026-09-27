#pragma once

#include <AudioToolbox/AudioToolbox.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <string>

namespace rillight_macos {

// Audio Queue Services is Core Audio's buffered PCM output. The callback only
// retires a buffer; all core calls and frame copies remain on the surface queue.
class CoreAudioOutput {
 public:
  CoreAudioOutput() {
    AudioStreamBasicDescription format{};
    format.mSampleRate = 48000;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger |
                          kLinearPCMFormatFlagIsPacked;
    format.mBytesPerPacket = 4;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 4;
    format.mChannelsPerFrame = 2;
    format.mBitsPerChannel = 16;
    const OSStatus created = AudioQueueNewOutput(
        &format, Callback, this, nullptr, nullptr, 0, &queue_);
    if (created != noErr) { Fail("AudioQueueNewOutput", created); return; }
    for (int i = 0; i < 3; ++i) {
      const OSStatus allocated = AudioQueueAllocateBuffer(queue_, 3840,
                                                           &buffers_[i]);
      if (allocated != noErr) { Fail("AudioQueueAllocateBuffer", allocated); return; }
    }
  }

  ~CoreAudioOutput() {
    if (queue_) AudioQueueDispose(queue_, true);
  }
  CoreAudioOutput(const CoreAudioOutput&) = delete;
  CoreAudioOutput& operator=(const CoreAudioOutput&) = delete;

  size_t Write(const uint8_t* data, size_t bytes) {
    if (!queue_ || !error_.empty() || paused_) return 0;
    for (int i = 0; i < 3; ++i) {
      if (!buffers_[i] || !free_[i].exchange(false)) continue;
      const size_t count = std::min(bytes, size_t{3840}) & ~size_t{3};
      if (!count) { free_[i] = true; return 0; }
      std::memcpy(buffers_[i]->mAudioData, data, count);
      buffers_[i]->mAudioDataByteSize = static_cast<UInt32>(count);
      const OSStatus enqueued = AudioQueueEnqueueBuffer(queue_, buffers_[i], 0,
                                                        nullptr);
      if (enqueued != noErr) {
        free_[i] = true;
        Fail("AudioQueueEnqueueBuffer", enqueued);
        return 0;
      }
      submitted_samples_ += count / 4;
      if (!started_) {
        const OSStatus started = AudioQueueStart(queue_, nullptr);
        if (started != noErr) { Fail("AudioQueueStart", started); return 0; }
        started_ = true;
      }
      return count;
    }
    return 0;
  }

  int64_t DelayUs() const {
    if (!queue_ || !started_) return 0;
    AudioTimeStamp stamp{};
    if (AudioQueueGetCurrentTime(queue_, nullptr, &stamp, nullptr) != noErr ||
        !(stamp.mFlags & kAudioTimeStampSampleTimeValid)) return -1;
    const double remaining = std::max(0.0, static_cast<double>(submitted_samples_) -
                                                stamp.mSampleTime);
    return static_cast<int64_t>(remaining * 1000000.0 / 48000.0);
  }

  void Pause(bool pause) {
    if (!queue_ || !started_ || paused_ == pause) return;
    const OSStatus status = pause ? AudioQueuePause(queue_)
                                  : AudioQueueStart(queue_, nullptr);
    if (status != noErr) Fail(pause ? "AudioQueuePause" : "AudioQueueStart", status);
    else paused_ = pause;
  }

  void Reset() {
    if (!queue_) return;
    // A seek may arrive before the first PCM buffer starts the queue. Stop is
    // also valid for an already started queue that is currently paused.
    if (started_) {
      const OSStatus stopped = AudioQueueStop(queue_, true);
      if (stopped != noErr) Fail("AudioQueueStop", stopped);
    }
    started_ = paused_ = false;
    submitted_samples_ = 0;
    for (auto& free : free_) free = true;
  }

  bool HasQueuedAudio() const {
    if (!started_) return false;
    const int64_t delay = DelayUs();
    return delay < 0 || delay > 1000;
  }
  const std::string& error() const { return error_; }

 private:
  static void Callback(void* opaque, AudioQueueRef, AudioQueueBufferRef buffer) {
    auto* self = static_cast<CoreAudioOutput*>(opaque);
    for (int i = 0; i < 3; ++i)
      if (self->buffers_[i] == buffer) {
        self->free_[i] = true;
        return;
      }
  }

  void Fail(const char* operation, OSStatus status) {
    error_ = std::string(operation) + " failed (" + std::to_string(status) + ")";
  }

  AudioQueueRef queue_ = nullptr;
  AudioQueueBufferRef buffers_[3]{};
  std::atomic<bool> free_[3] = {true, true, true};
  uint64_t submitted_samples_ = 0;
  bool started_ = false;
  bool paused_ = false;
  std::string error_;
};

}  // namespace rillight_macos
