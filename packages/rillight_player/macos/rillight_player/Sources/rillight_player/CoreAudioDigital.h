#pragma once

#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/HostTime.h>
#include <AudioToolbox/AudioToolbox.h>
#include <unistd.h>
#include <chrono>
#include <thread>
#include "DigitalAudioBuffer.h"
#include "../../../../native/core/audio_passthrough.h"
#include "../../../../native/core/iec61937_pack.h"

namespace rillight_macos {
inline AudioObjectPropertyAddress OutputProperty(AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
  return {selector, scope, kAudioObjectPropertyElementMain};
}
template<class T> bool AudioRead(AudioObjectID object, AudioObjectPropertyAddress address, T* value) {
  UInt32 size = sizeof(T);
  return AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, value) == noErr && size == sizeof(T);
}
template<class T> bool AudioWrite(AudioObjectID object, AudioObjectPropertyAddress address, const T& value) {
  return AudioObjectSetPropertyData(object, &address, 0, nullptr, sizeof(T), &value) == noErr;
}
template<class T> std::vector<T> AudioArray(AudioObjectID object, AudioObjectPropertyAddress address) {
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(object, &address, 0, nullptr, &size) != noErr ||
      size % sizeof(T) || size > 1024 * 1024) return {};
  std::vector<T> values(size / sizeof(T));
  if (size && AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, values.data()) != noErr) return {};
  values.resize(size / sizeof(T));
  return values;
}
inline AudioDeviceID DigitalDefaultDevice() {
  AudioDeviceID device = kAudioObjectUnknown;
  AudioRead(kAudioObjectSystemObject, OutputProperty(kAudioHardwarePropertyDefaultOutputDevice), &device);
  return device;
}
inline bool IsDigitalFormat(AudioFormatID format) {
  // Explicit encoded driver formats only. Never disguise IEC bytes as float
  // PCM on a normal speaker/Bluetooth route.
  return format == kAudioFormat60958AC3 || format == kAudioFormatAC3 ||
      format == 0x49414333u || format == 0x69616333u;
}
inline bool MatchesCarrier(const AudioStreamBasicDescription& format, RillightAudioCarrier carrier) {
  const UInt32 stride = format.mBytesPerFrame ? format.mBytesPerFrame :
      (format.mFramesPerPacket ? format.mBytesPerPacket / format.mFramesPerPacket : 0);
  return carrier.rate > 0 && format.mSampleRate == carrier.rate &&
      format.mChannelsPerFrame == static_cast<UInt32>(carrier.channels) &&
      stride == static_cast<UInt32>(carrier.channels * 2) &&
      (format.mBitsPerChannel == 0 || format.mBitsPerChannel == 16) &&
      !(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
}
inline bool SetPhysicalFormat(AudioStreamID stream, const AudioStreamBasicDescription& format) {
  const auto address = OutputProperty(kAudioStreamPropertyPhysicalFormat);
  if (!AudioWrite(stream, address, format)) return false;
  // Core Audio applies physical-format changes asynchronously. Wait before
  // either starting encoded I/O or handing the device back to AudioQueue.
  for (int attempt = 0; attempt < 50; ++attempt) {
    AudioStreamBasicDescription observed{};
    if (AudioRead(stream, address, &observed) &&
        observed.mFormatID == format.mFormatID &&
        observed.mSampleRate == format.mSampleRate &&
        observed.mChannelsPerFrame == format.mChannelsPerFrame &&
        observed.mBytesPerFrame == format.mBytesPerFrame &&
        observed.mFormatFlags == format.mFormatFlags) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  return false;
}
struct DigitalSelection {
  AudioDeviceID device = kAudioObjectUnknown;
  AudioStreamID stream = kAudioObjectUnknown;
  UInt32 buffer = 0;
  AudioStreamBasicDescription format{};
};
inline DigitalSelection SelectDigitalFormat(AudioDeviceID device, RillightAudioCarrier carrier) {
  const auto streams = AudioArray<AudioStreamID>(device,
      OutputProperty(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput));
  for (size_t index = 0; index < streams.size(); ++index) {
    const auto formats = AudioArray<AudioStreamRangedDescription>(streams[index],
        OutputProperty(kAudioStreamPropertyAvailablePhysicalFormats));
    for (const auto& available : formats) {
      auto format = available.mFormat;
      if (carrier.rate < available.mSampleRateRange.mMinimum ||
          carrier.rate > available.mSampleRateRange.mMaximum) continue;
      format.mSampleRate = carrier.rate;
      if (IsDigitalFormat(format.mFormatID) && MatchesCarrier(format, carrier))
        return {device, streams[index], static_cast<UInt32>(index), format};
    }
  }
  return {};
}
inline uint32_t DigitalAcceptedFormats(AudioDeviceID device) {
  if (device == kAudioObjectUnknown) return 0;
  uint32_t accepted = 0;
  for (int kind = 1; kind <= 6; ++kind)
    for (int rate : {44100, 48000})
      if (SelectDigitalFormat(device, rillight_audio_carrier(kind, rate)).stream != kAudioObjectUnknown)
        accepted |= rillight_passthrough_accept_bit(kind);
  return accepted;
}

class CoreAudioDigital {
 public:
  CoreAudioDigital(int kind, int source_rate) : kind_(kind), source_rate_(source_rate),
      carrier_(rillight_audio_carrier(kind, source_rate)) {
    selection_ = SelectDigitalFormat(DigitalDefaultDevice(), carrier_);
    if (!selection_.stream) { failed_ = true; return; }
    const auto hog = OutputProperty(kAudioDevicePropertyHogMode);
    pid_t owner = -1;
    if (!AudioRead(selection_.device, hog, &owner) || owner != -1 ||
        !AudioWrite(selection_.device, hog, getpid())) { failed_ = true; return; }
    owns_device_ = true;
    if (!AudioRead(selection_.device, hog, &owner) || owner != getpid()) { failed_ = true; return; }
    const auto mix = OutputProperty(kAudioDevicePropertySupportsMixing);
    if (AudioObjectHasProperty(selection_.device, &mix)) {
      if (!AudioRead(selection_.device, mix, &old_mixing_)) { failed_ = true; return; }
      if (old_mixing_ != 0) {
        if (!AudioWrite(selection_.device, mix, UInt32{0})) { failed_ = true; return; }
        changed_mixing_ = true;
      }
    }
    const auto physical = OutputProperty(kAudioStreamPropertyPhysicalFormat);
    if (!AudioRead(selection_.stream, physical, &original_)) { failed_ = true; return; }
    changed_format_ = true;
    const bool applied = SetPhysicalFormat(selection_.stream, selection_.format);
    AudioStreamBasicDescription logical{};
    if (!applied || !AudioRead(selection_.stream,
        OutputProperty(kAudioStreamPropertyVirtualFormat), &logical) ||
        !IsDigitalFormat(logical.mFormatID) || !MatchesCarrier(logical, carrier_)) {
      failed_ = true; return;
    }
    swap_words_ = (logical.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0;
    UInt32 device_latency = 0, stream_latency = 0;
    AudioRead(selection_.device, OutputProperty(kAudioDevicePropertyLatency,
        kAudioDevicePropertyScopeOutput), &device_latency);
    AudioRead(selection_.stream, OutputProperty(kAudioStreamPropertyLatency), &stream_latency);
    latency_ns_ = (uint64_t(device_latency) + stream_latency) * 1000000000 / carrier_.rate;
    if (AudioObjectAddPropertyListener(selection_.stream, &physical, Changed, this) != noErr) {
      failed_ = true; return;
    }
    listening_ = true;
    if (AudioDeviceCreateIOProcID(selection_.device, Render, this, &callback_) != noErr)
      failed_ = true;
  }
  ~CoreAudioDigital() {
    Stop();
    if (callback_) AudioDeviceDestroyIOProcID(selection_.device, callback_);
    const auto physical = OutputProperty(kAudioStreamPropertyPhysicalFormat);
    if (listening_) AudioObjectRemovePropertyListener(selection_.stream, &physical, Changed, this);
    if (changed_format_) SetPhysicalFormat(selection_.stream, original_);
    if (changed_mixing_) AudioWrite(selection_.device,
        OutputProperty(kAudioDevicePropertySupportsMixing), old_mixing_);
    if (owns_device_) {
      pid_t owner = -1;
      const auto hog = OutputProperty(kAudioDevicePropertyHogMode);
      if (AudioRead(selection_.device, hog, &owner) && owner == getpid())
        AudioWrite(selection_.device, hog, pid_t{-1});
    }
  }
  bool failed() const { return failed_.load(); }
  int kind() const { return kind_; }
  int sample_rate() const { return source_rate_; }
  size_t Write(const uint8_t* data, size_t size, int samples) {
    CheckDevice();
    if (failed() || paused_) return 0;
    if (size > INT32_MAX || samples <= 0) { failed_ = true; return 0; }
    if (held_ != data) {
      int result = -1;
      if (kind_ == RILLIGHT_CORE_PASSTHROUGH_AC3) result = mux_.push_ac3(data, static_cast<int>(size), &burst_);
      else if (kind_ == RILLIGHT_CORE_PASSTHROUGH_EAC3 || kind_ == RILLIGHT_CORE_PASSTHROUGH_EAC3_JOC)
        result = mux_.push_eac3(data, static_cast<int>(size), &burst_);
      else if (kind_ == RILLIGHT_CORE_PASSTHROUGH_TRUEHD) result = mux_.push_truehd(data, static_cast<int>(size), &burst_);
      else if (kind_ == RILLIGHT_CORE_PASSTHROUGH_DTS || kind_ == RILLIGHT_CORE_PASSTHROUGH_DTSHD)
        result = mux_.push_dts(data, static_cast<int>(size), kind_ == RILLIGHT_CORE_PASSTHROUGH_DTSHD, &burst_);
      if (result < 0) { failed_ = true; return 0; }
      staged_us_ += int64_t(samples) * 1000000 / source_rate_;
      if (!result) return size;
      held_ = data;
    }
    if (!buffer_.Push(burst_.data(), burst_.size(), swap_words_)) return 0;
    staged_us_ = 0;
    held_ = nullptr;
    burst_.clear();
    if (!started_) {
      if (AudioDeviceStart(selection_.device, callback_) != noErr) { failed_ = true; return 0; }
      started_ = true;
      last_callback_ns_.store(NowNs());
    }
    return size;
  }
  int64_t DelayUs() {
    CheckDevice();
    if (failed()) return -1;
    const int64_t now = static_cast<int64_t>(AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()));
    const auto pending = buffer_.pending();
    return staged_us_ + static_cast<int64_t>(pending * 1000000 /
        (uint64_t(carrier_.rate) * carrier_.channels * 2)) +
        std::max<int64_t>(0, due_ns_.load() - now) / 1000;
  }
  void Pause(bool value) { paused_.store(value); }
  void Reset() {
    Stop();
    buffer_.Reset();
    due_ns_ = 0;
    staged_us_ = 0;
    paused_ = false;
    held_ = nullptr;
    burst_.clear();
    mux_.reset();
  }
 private:
  static int64_t NowNs() {
    return static_cast<int64_t>(AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()));
  }
  void CheckDevice() {
    if (failed()) return;
    if (format_changed_.exchange(false)) {
      AudioStreamBasicDescription physical{};
      if (!AudioRead(selection_.stream, OutputProperty(kAudioStreamPropertyPhysicalFormat), &physical) ||
          !IsDigitalFormat(physical.mFormatID) || !MatchesCarrier(physical, carrier_)) failed_ = true;
    }
    if (started_ && !paused_ && NowNs() - last_callback_ns_.load() > 2000000000LL) failed_ = true;
  }
  void Stop() {
    if (started_ && callback_) AudioDeviceStop(selection_.device, callback_);
    started_ = false;
  }
  static OSStatus Changed(AudioObjectID, UInt32, const AudioObjectPropertyAddress*, void* opaque) {
    static_cast<CoreAudioDigital*>(opaque)->format_changed_ = true;
    return noErr;
  }
  static OSStatus Render(AudioDeviceID, const AudioTimeStamp*, const AudioBufferList*,
      const AudioTimeStamp*, AudioBufferList* output, const AudioTimeStamp* when, void* opaque) {
    auto* self = static_cast<CoreAudioDigital*>(opaque);
    self->last_callback_ns_.store(NowNs());
    if (!output) return noErr;
    for (UInt32 index = 0; index < output->mNumberBuffers; ++index) {
      auto& target = output->mBuffers[index];
      if (!target.mData) continue;
      if (index != self->selection_.buffer || self->paused_ || self->failed()) {
        std::memset(target.mData, 0, target.mDataByteSize); continue;
      }
      const auto stride = self->carrier_.channels * 2;
      if (target.mNumberChannels != static_cast<UInt32>(self->carrier_.channels) ||
          target.mDataByteSize % stride != 0) {
        self->failed_ = true;
        std::memset(target.mData, 0, target.mDataByteSize); continue;
      }
      const auto count = self->buffer_.Read(static_cast<uint8_t*>(target.mData), target.mDataByteSize);
      if (count) {
        const uint64_t host = when && (when->mFlags & kAudioTimeStampHostTimeValid)
            ? when->mHostTime : AudioGetCurrentHostTime();
        self->due_ns_ = static_cast<int64_t>(AudioConvertHostTimeToNanos(host) + self->latency_ns_ +
            count * 1000000000 / (uint64_t(self->carrier_.rate) * stride));
      }
    }
    if (self->selection_.buffer >= output->mNumberBuffers) self->failed_ = true;
    return noErr;
  }
  int kind_, source_rate_;
  RillightAudioCarrier carrier_;
  DigitalSelection selection_;
  AudioStreamBasicDescription original_{};
  AudioDeviceIOProcID callback_ = nullptr;
  bool owns_device_ = false, changed_mixing_ = false, changed_format_ = false;
  bool listening_ = false, started_ = false, swap_words_ = false;
  UInt32 old_mixing_ = 0;
  std::atomic<bool> failed_{false}, paused_{false};
  std::atomic<bool> format_changed_{false};
  std::atomic<int64_t> due_ns_{0};
  std::atomic<int64_t> last_callback_ns_{0};
  uint64_t latency_ns_ = 0;
  int64_t staged_us_ = 0;
  DigitalAudioBuffer buffer_;
  RillightIec61937Mux mux_;
  std::vector<uint8_t> burst_;
  const uint8_t* held_ = nullptr;
};
}  // namespace rillight_macos
