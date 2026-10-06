#pragma once

#include <pulse/error.h>
#include <pulse/format.h>
#include <pulse/pulseaudio.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "../native/core/iec61937_pack.h"
#include "../native/core/rillight_core.h"

namespace rillight_linux {

inline int PcmChannelTarget(int channels) {
  if (channels >= 8) return 8;
  if (channels >= 6) return 6;
  return 2;
}

// Failure leaves stereo PCM and no passthrough bits. Surface creation must
// not depend on a running Pulse daemon.
inline bool ProbeDefaultSink(int *channels, uint32_t *accept) {
  if (channels) *channels = 2;
  if (accept) *accept = 0;
  pa_mainloop *loop = pa_mainloop_new();
  if (!loop) return false;
  pa_context *context = pa_context_new(pa_mainloop_get_api(loop), "Rillight");
  if (!context || pa_context_connect(context, nullptr, PA_CONTEXT_NOFLAGS,
                                    nullptr) < 0) {
    if (context) pa_context_unref(context);
    pa_mainloop_free(loop);
    return false;
  }
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  auto ready = [&] {
    while (std::chrono::steady_clock::now() < deadline) {
      if (pa_mainloop_iterate(loop, 0, nullptr) < 0) return false;
      const auto state = pa_context_get_state(context);
      if (state == PA_CONTEXT_READY) return true;
      if (state == PA_CONTEXT_FAILED || state == PA_CONTEXT_TERMINATED)
        return false;
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    return false;
  };
  struct SinkProbe {
    std::string name;
    int channels = 2;
    uint32_t accept = 0;
    bool done = false;
  } probe;
  if (!ready()) {
    pa_context_disconnect(context);
    pa_context_unref(context);
    pa_mainloop_free(loop);
    return false;
  }
  pa_operation *server = pa_context_get_server_info(
      context,
      [](pa_context *, const pa_server_info *info, void *opaque) {
        auto *probe = static_cast<SinkProbe *>(opaque);
        if (info && info->default_sink_name) probe->name = info->default_sink_name;
        probe->done = true;
      },
      &probe);
  if (!server) {
    pa_context_disconnect(context);
    pa_context_unref(context);
    pa_mainloop_free(loop);
    return false;
  }
  while (!probe.done && std::chrono::steady_clock::now() < deadline) {
    if (pa_mainloop_iterate(loop, 0, nullptr) < 0) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  pa_operation_unref(server);
  if (probe.name.empty()) {
    pa_context_disconnect(context);
    pa_context_unref(context);
    pa_mainloop_free(loop);
    return false;
  }
  probe.done = false;
  pa_operation *sink = pa_context_get_sink_info_by_name(
      context, probe.name.c_str(),
      [](pa_context *, const pa_sink_info *info, int eol, void *opaque) {
        auto *probe = static_cast<SinkProbe *>(opaque);
        if (eol > 0 || !info) {
          probe->done = true;
          return;
        }
        probe->channels = PcmChannelTarget(info->channel_map.channels);
        if (info->formats) {
          for (uint8_t index = 0; index < info->n_formats; ++index) {
            const pa_encoding_t encoding =
                pa_format_info_get_encoding(info->formats[index]);
            if (encoding == PA_ENCODING_EAC3_IEC61937)
              probe->accept |= RILLIGHT_CORE_AUDIO_ACCEPT_EAC3;
            if (encoding == PA_ENCODING_TRUEHD_IEC61937)
              probe->accept |= RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD;
          }
        }
      },
      &probe);
  if (sink) {
    while (!probe.done && std::chrono::steady_clock::now() < deadline) {
      if (pa_mainloop_iterate(loop, 0, nullptr) < 0) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    pa_operation_unref(sink);
  }
  if (channels) *channels = probe.channels;
  if (accept) *accept = probe.accept;
  pa_context_disconnect(context);
  pa_context_unref(context);
  pa_mainloop_free(loop);
  return true;
}

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
    alive_ = false;
    CloseStream();
    if (context_) {
      pa_context_set_subscribe_callback(context_, nullptr, nullptr);
      pa_context_disconnect(context_);
      pa_context_unref(context_);
    }
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
    PollRoute();
    if (!stream_) return true;
    const auto stream_state = pa_stream_get_state(stream_);
    if (stream_state == PA_STREAM_FAILED || stream_state == PA_STREAM_TERMINATED) {
      // A compressed format the sink will not keep is not a dead audio thread.
      // PCM follows the new default sink instead of stopping the surface.
      if (passthrough_kind_ != 0) {
        RejectPassthrough(passthrough_kind_);
        return true;
      }
      if (++pcm_failures_ > 3) {
        error_ = std::string("PulseAudio stream: ") +
                 pa_strerror(pa_context_errno(context_));
        CloseStream();
        return false;
      }
      CloseStream();
      error_.clear();
      return true;
    }
    if (stream_state != PA_STREAM_READY) {
      if (now - started_ > std::chrono::seconds(5)) {
        if (passthrough_kind_ != 0) {
          RejectPassthrough(passthrough_kind_);
          return true;
        }
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
  bool EnsurePcm(int channels) {
    if (channels < 1) channels = 2;
    if (channels > 8) channels = 8;
    return Ensure(channels, 0);
  }
  bool EnsurePassthrough(int kind) {
    if (passthrough_rejected_) return false;
    if (kind != RILLIGHT_CORE_PASSTHROUGH_EAC3_JOC &&
        kind != RILLIGHT_CORE_PASSTHROUGH_TRUEHD) {
      passthrough_rejected_ = true;
      return false;
    }
    return Ensure(2, kind);
  }
  bool passthrough_rejected() const { return passthrough_rejected_; }
  int rejected_passthrough_kind() const { return rejected_kind_; }
  int current_passthrough_kind() const { return passthrough_kind_; }
  int route_generation() const { return route_generation_; }
  void copy_route(int *channels, uint32_t *accept) const {
    if (channels) *channels = route_channels_;
    if (accept) *accept = route_accept_;
  }
  void AbandonPassthrough() {
    passthrough_rejected_ = false;
    rejected_kind_ = 0;
    if (error_ == "IEC 61937 burst does not fit") error_.clear();
    mux_.reset();
    burst_.clear();
    burst_offset_ = 0;
    held_packet_ = nullptr;
    if (passthrough_kind_ != 0) CloseStream();
  }
  size_t Write(const uint8_t* data, size_t size) {
    if (!stream_ || pa_stream_get_state(stream_) != PA_STREAM_READY ||
        Latency() < 0) return 0;
    const size_t writable = pa_stream_writable_size(stream_);
    if (writable == static_cast<size_t>(-1)) {
      NoteWriteFailure("PulseAudio writable size failed");
      return 0;
    }
    const size_t quantum = size_t{1920} *
                           static_cast<size_t>(std::max(channels_, 2)) / 2;
    size_t chunk = std::min({size, writable, quantum});
    if (stride_ > 1) chunk -= chunk % static_cast<size_t>(stride_);
    if (chunk == 0) return 0;
    if (pa_stream_write(stream_, data, chunk, nullptr, 0,
                        PA_SEEK_RELATIVE) < 0) {
      NoteWriteFailure(std::string("PulseAudio write: ") +
                       pa_strerror(pa_context_errno(context_)));
      return 0;
    }
    pcm_failures_ = 0;
    return chunk;
  }
  // Returns the consumed compressed size, 0 when the device needs another
  // iteration, or static_cast<size_t>(-1) when the burst cannot be packed.
  size_t WriteCompressed(int kind, const uint8_t *data, size_t size) {
    if (!EnsurePassthrough(kind)) return passthrough_rejected_ ? size_t(-1) : 0;
    if (!stream_ || pa_stream_get_state(stream_) != PA_STREAM_READY ||
        Latency() < 0) return 0;
    if (held_packet_ != data) {
      std::vector<uint8_t> produced;
      const int packed = kind == RILLIGHT_CORE_PASSTHROUGH_TRUEHD
                             ? mux_.push_truehd(data, static_cast<int>(size),
                                                &produced)
                             : mux_.push_eac3(data, static_cast<int>(size),
                                              &produced);
      if (packed < 0) {
        RejectPassthrough(kind);
        return size_t(-1);
      }
      held_packet_ = data;
      if (packed == 0) {
        held_packet_ = nullptr;
        return size;
      }
      burst_ = std::move(produced);
      burst_offset_ = 0;
    }
    if (!FlushBurst()) return 0;
    held_packet_ = nullptr;
    return size;
  }
  int64_t Latency() const {
    if (!stream_ || pa_stream_get_state(stream_) != PA_STREAM_READY) return -1;
    pa_usec_t delay = 0;
    int negative = 0;
    if (pa_stream_get_latency(stream_, &delay, &negative) < 0) return -1;
    return negative ? 0 : static_cast<int64_t>(delay);
  }
  void Flush() {
    mux_.reset();
    burst_.clear();
    burst_offset_ = 0;
    held_packet_ = nullptr;
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
  bool Ensure(int channels, int kind) {
    if (!error_.empty() && !passthrough_rejected_) return false;
    if (!context_ || pa_context_get_state(context_) != PA_CONTEXT_READY)
      return false;
    if (stream_ && channels_ == channels && passthrough_kind_ == kind &&
        pa_stream_get_state(stream_) != PA_STREAM_FAILED &&
        pa_stream_get_state(stream_) != PA_STREAM_TERMINATED)
      return true;
    CloseStream();
    channels_ = channels;
    passthrough_kind_ = kind;
    stride_ = kind == 0 ? std::max(1, channels) * 2 : 1;
    started_ = std::chrono::steady_clock::now();
    if (kind == 0) {
      pa_sample_spec spec{PA_SAMPLE_S16NE, 48000,
                          static_cast<uint8_t>(channels)};
      pa_channel_map map;
      pa_channel_map_init_auto(&map, static_cast<unsigned>(channels),
                               PA_CHANNEL_MAP_WAVEEX);
      stream_ = pa_stream_new(context_, "Media", &spec, &map);
    } else {
      pa_format_info *info = pa_format_info_new();
      pa_format_info_set_encoding(
          info, kind == RILLIGHT_CORE_PASSTHROUGH_TRUEHD
                    ? PA_ENCODING_TRUEHD_IEC61937
                    : PA_ENCODING_EAC3_IEC61937);
      pa_format_info_set_rate(info, 48000);
      pa_format_info_set_channels(info, channels);
      pa_format_info *formats[] = {info};
      stream_ = pa_stream_new_extended(context_, "Media", formats, 1, nullptr);
      pa_format_info_free(info);
    }
    if (!stream_) {
      NoteWriteFailure("PulseAudio stream unavailable");
      return false;
    }
    pa_buffer_attr attributes{};
    attributes.maxlength = static_cast<uint32_t>(-1);
    const uint32_t scale = kind == 0
                               ? static_cast<uint32_t>(std::max(channels, 2) / 2)
                               : 1u;
    attributes.tlength = kind == 0 ? 4800u * scale : 61440u;
    attributes.prebuf = 0;
    attributes.minreq = kind == 0 ? 1920u * scale : 2048u;
    attributes.fragsize = static_cast<uint32_t>(-1);
    const auto flags = static_cast<pa_stream_flags_t>(
        PA_STREAM_ADJUST_LATENCY | PA_STREAM_AUTO_TIMING_UPDATE |
        PA_STREAM_INTERPOLATE_TIMING);
    if (pa_stream_connect_playback(stream_, nullptr, &attributes, flags,
                                   nullptr, nullptr) < 0) {
      NoteWriteFailure(std::string("PulseAudio stream: ") +
                       pa_strerror(pa_context_errno(context_)));
      return false;
    }
    return true;
  }
  void RejectPassthrough(int kind) {
    if (kind != RILLIGHT_CORE_PASSTHROUGH_EAC3_JOC &&
        kind != RILLIGHT_CORE_PASSTHROUGH_TRUEHD)
      kind = passthrough_kind_ != 0 ? passthrough_kind_
                                    : RILLIGHT_CORE_PASSTHROUGH_EAC3_JOC;
    rejected_kind_ = kind;
    passthrough_rejected_ = true;
    mux_.reset();
    burst_.clear();
    burst_offset_ = 0;
    held_packet_ = nullptr;
    CloseStream();
  }
  void NoteWriteFailure(const std::string &message) {
    if (passthrough_kind_ != 0) {
      RejectPassthrough(passthrough_kind_);
      return;
    }
    error_ = message;
  }
  void PollRoute() {
    if (!alive_ || !context_ || pa_context_get_state(context_) != PA_CONTEXT_READY)
      return;
    if (!subscribed_) {
      pa_context_set_subscribe_callback(
          context_,
          [](pa_context *, pa_subscription_event_type_t, uint32_t, void *opaque) {
            static_cast<PulseOutput *>(opaque)->route_dirty_ = true;
          },
          this);
      if (auto *operation = pa_context_subscribe(
              context_,
              static_cast<pa_subscription_mask_t>(PA_SUBSCRIPTION_MASK_SERVER |
                                                  PA_SUBSCRIPTION_MASK_SINK),
              nullptr, nullptr))
        pa_operation_unref(operation);
      subscribed_ = true;
      route_dirty_ = true;
    }
    if (!route_dirty_ || route_querying_) return;
    route_dirty_ = false;
    route_querying_ = true;
    pa_operation *server = pa_context_get_server_info(
        context_,
        [](pa_context *context, const pa_server_info *info, void *opaque) {
          auto *self = static_cast<PulseOutput *>(opaque);
          if (!self->alive_ || !info || !info->default_sink_name) {
            self->route_querying_ = false;
            return;
          }
          pa_operation *sink = pa_context_get_sink_info_by_name(
              context, info->default_sink_name,
              [](pa_context *, const pa_sink_info *info, int eol, void *opaque) {
                auto *self = static_cast<PulseOutput *>(opaque);
                if (eol > 0 || !info || !self->alive_) {
                  self->route_querying_ = false;
                  return;
                }
                uint32_t accept = 0;
                if (info->formats) {
                  for (uint8_t index = 0; index < info->n_formats; ++index) {
                    const pa_encoding_t encoding =
                        pa_format_info_get_encoding(info->formats[index]);
                    if (encoding == PA_ENCODING_EAC3_IEC61937)
                      accept |= RILLIGHT_CORE_AUDIO_ACCEPT_EAC3;
                    if (encoding == PA_ENCODING_TRUEHD_IEC61937)
                      accept |= RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD;
                  }
                }
                self->route_channels_ = PcmChannelTarget(info->channel_map.channels);
                self->route_accept_ = accept;
                self->route_generation_ += 1;
              },
              self);
          if (!sink) self->route_querying_ = false;
          else pa_operation_unref(sink);
        },
        this);
    if (!server) route_querying_ = false;
    else pa_operation_unref(server);
  }
  bool FlushBurst() {
    while (burst_offset_ < burst_.size()) {
      const size_t writable = pa_stream_writable_size(stream_);
      if (writable == static_cast<size_t>(-1)) {
        NoteWriteFailure("PulseAudio writable size failed");
        return false;
      }
      const size_t chunk = std::min(burst_.size() - burst_offset_, writable);
      if (chunk == 0) return false;
      if (pa_stream_write(stream_, burst_.data() + burst_offset_, chunk,
                          nullptr, 0, PA_SEEK_RELATIVE) < 0) {
        NoteWriteFailure(std::string("PulseAudio write: ") +
                         pa_strerror(pa_context_errno(context_)));
        return false;
      }
      burst_offset_ += chunk;
    }
    burst_.clear();
    burst_offset_ = 0;
    return true;
  }
  void CloseStream() {
    if (stream_) {
      pa_stream_disconnect(stream_);
      pa_stream_unref(stream_);
      stream_ = nullptr;
    }
    requested_timing_ = false;
    channels_ = 0;
    passthrough_kind_ = 0;
    stride_ = 4;
  }
  void RequestTiming() {
    if (!stream_) return;
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
  int channels_ = 0;
  int stride_ = 4;
  int passthrough_kind_ = 0;
  int rejected_kind_ = 0;
  int pcm_failures_ = 0;
  bool passthrough_rejected_ = false;
  bool alive_ = true;
  bool subscribed_ = false;
  bool route_dirty_ = false;
  bool route_querying_ = false;
  int route_generation_ = 0;
  int route_channels_ = 2;
  uint32_t route_accept_ = 0;
  RillightIec61937Mux mux_;
  std::vector<uint8_t> burst_;
  size_t burst_offset_ = 0;
  const uint8_t *held_packet_ = nullptr;
};

}  // namespace rillight_linux
