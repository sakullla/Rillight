#pragma once

#include <pulse/error.h>
#include <pulse/pulseaudio.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <string>

namespace rillight_linux {

// PulseAudio is driven from the surface worker with nonblocking mainloop
// iterations. A suspended sink cannot trap texture detach in a blocking write.
class PulseOutput {
 public:
  PulseOutput() {
    loop_ = pa_mainloop_new();
    if (!loop_) { error_ = "PulseAudio mainloop unavailable"; return; }
    context_ = pa_context_new(pa_mainloop_get_api(loop_), "Rillight");
    if (!context_ || pa_context_connect(context_, nullptr, PA_CONTEXT_NOFLAGS,
                                        nullptr) < 0)
      error_ = "PulseAudio connection unavailable";
  }
  ~PulseOutput() {
    if (stream_) { pa_stream_disconnect(stream_); pa_stream_unref(stream_); }
    if (context_) { pa_context_disconnect(context_); pa_context_unref(context_); }
    if (loop_) pa_mainloop_free(loop_);
  }
  bool Pump() {
    if (!error_.empty()) return false;
    int result = 0;
    if (pa_mainloop_iterate(loop_, 0, &result) < 0) {
      error_ = "PulseAudio mainloop failed"; return false;
    }
    const auto now = std::chrono::steady_clock::now();
    const auto state = pa_context_get_state(context_);
    if (state == PA_CONTEXT_FAILED || state == PA_CONTEXT_TERMINATED) {
      error_ = std::string("PulseAudio: ") + pa_strerror(pa_context_errno(context_));
      return false;
    }
    if (state != PA_CONTEXT_READY) {
      if (now - started_ > std::chrono::seconds(5)) {
        error_ = "PulseAudio connection timed out";
        return false;
      }
      return true;
    }
    if (!stream_) {
      const pa_sample_spec spec{PA_SAMPLE_S16NE, 48000, 2};
      stream_ = pa_stream_new(context_, "Media", &spec, nullptr);
      if (!stream_) { error_ = "PulseAudio stream unavailable"; return false; }
      started_ = now;
      pa_buffer_attr attributes{};
      attributes.maxlength = static_cast<uint32_t>(-1);
      attributes.tlength = 4800;
      attributes.prebuf = 0;
      attributes.minreq = 1920;
      attributes.fragsize = static_cast<uint32_t>(-1);
      const auto flags = static_cast<pa_stream_flags_t>(
          PA_STREAM_ADJUST_LATENCY | PA_STREAM_AUTO_TIMING_UPDATE |
          PA_STREAM_INTERPOLATE_TIMING);
      if (pa_stream_connect_playback(stream_, nullptr, &attributes, flags,
                                     nullptr, nullptr) < 0) {
        error_ = std::string("PulseAudio stream: ") +
                 pa_strerror(pa_context_errno(context_));
        return false;
      }
    }
    const auto stream_state = pa_stream_get_state(stream_);
    if (stream_state == PA_STREAM_FAILED || stream_state == PA_STREAM_TERMINATED) {
      error_ = std::string("PulseAudio stream: ") +
               pa_strerror(pa_context_errno(context_));
      return false;
    }
    if (stream_state != PA_STREAM_READY) {
      if (now - started_ > std::chrono::seconds(5)) {
        error_ = "PulseAudio stream timed out";
        return false;
      }
      return true;
    }
    if (!requested_timing_) {
      requested_timing_ = true;
      RequestTiming();
    }
    if (Latency() < 0) {
      if (timing_missing_since_ == std::chrono::steady_clock::time_point{})
        timing_missing_since_ = now;
      if (now - last_timing_request_ > std::chrono::milliseconds(250))
        RequestTiming();
      if (now - timing_missing_since_ > std::chrono::seconds(2)) {
        error_ = "PulseAudio timing unavailable";
        return false;
      }
    } else {
      timing_missing_since_ = {};
    }
    return true;
  }
  size_t Write(const uint8_t* data, size_t size) {
    if (!stream_ || pa_stream_get_state(stream_) != PA_STREAM_READY ||
        Latency() < 0) return 0;
    const size_t writable = pa_stream_writable_size(stream_);
    if (writable == static_cast<size_t>(-1)) {
      error_ = "PulseAudio writable size failed"; return 0;
    }
    const size_t chunk = std::min({size, writable, size_t{1920}}) & ~size_t{3};
    if (chunk == 0) return 0;
    if (pa_stream_write(stream_, data, chunk, nullptr, 0,
                        PA_SEEK_RELATIVE) < 0) {
      error_ = std::string("PulseAudio write: ") +
               pa_strerror(pa_context_errno(context_));
      return 0;
    }
    return chunk;
  }
  int64_t Latency() const {
    if (!stream_ || pa_stream_get_state(stream_) != PA_STREAM_READY) return -1;
    pa_usec_t delay = 0;
    int negative = 0;
    if (pa_stream_get_latency(stream_, &delay, &negative) < 0) return -1;
    return negative ? 0 : static_cast<int64_t>(delay);
  }
  void Flush() {
    if (!stream_ || pa_stream_get_state(stream_) != PA_STREAM_READY) return;
    if (auto* operation = pa_stream_flush(stream_, nullptr, nullptr))
      pa_operation_unref(operation);
    timing_missing_since_ = {};
    RequestTiming();
  }
  void Cork(bool paused) {
    if (!stream_ || pa_stream_get_state(stream_) != PA_STREAM_READY) return;
    if (auto* operation = pa_stream_cork(stream_, paused ? 1 : 0,
                                         nullptr, nullptr))
      pa_operation_unref(operation);
  }
  const std::string& error() const { return error_; }
 private:
  void RequestTiming() {
    if (auto* operation = pa_stream_update_timing_info(stream_, nullptr,
                                                        nullptr))
      pa_operation_unref(operation);
    last_timing_request_ = std::chrono::steady_clock::now();
  }
  pa_mainloop* loop_ = nullptr;
  pa_context* context_ = nullptr;
  pa_stream* stream_ = nullptr;
  std::string error_;
  std::chrono::steady_clock::time_point started_ =
      std::chrono::steady_clock::now();
  std::chrono::steady_clock::time_point last_timing_request_{};
  std::chrono::steady_clock::time_point timing_missing_since_{};
  bool requested_timing_ = false;
};

}  // namespace rillight_linux
