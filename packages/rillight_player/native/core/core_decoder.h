#pragma once

#include "core_common.h"

namespace rillight::core {
struct HardwareFormatSelection {
  AVPixelFormat preferred = AV_PIX_FMT_NONE;
  bool allow_software_fallback = true;
};

struct TunnelDecoder {
  std::shared_ptr<AndroidTunnelFactory> factory;
  std::shared_ptr<AndroidTunnelSink> sink;
  std::shared_ptr<void> window;
  AVBSFContext* filter = nullptr;
  std::mutex mutex;
  std::vector<uint8_t> csd, config;
  int width = 0, height = 0, profile = 0, level = 0, rate = 25;
  AVRational time_base{1, 1000000};
  int64_t discard_before = 0;
  std::atomic<int64_t> submitted{-1};
  int64_t emitted = -1;
  ~TunnelDecoder() { av_bsf_free(&filter); }
};

struct Decoder {
  AVCodecContext *context = nullptr;
  int stream = -1;
  std::shared_ptr<HardwareFormatSelection> hw_format;
  uint32_t hardware = RILLIGHT_CORE_HW_NONE;
  bool android_color_buffers = false;
  bool android_native_dolby = false;
  std::shared_ptr<TunnelDecoder> tunnel;
  std::shared_ptr<AndroidDoviSurface> android_dovi_surface;
  int error = 0;
  // Human-readable decode-path negotiation for remote triage: adapter,
  // capability probe, thread budget and any fallback reason.
  std::string diagnostics;
  std::string hardware_diagnostics;
  int decoded_hardware = -1;
  DtsPacketRecovery dts_recovery;
};

struct PendingPackets {
  std::deque<AVPacket*> values;
  ~PendingPackets() { Clear(); }
  void Clear() { for (auto* packet : values) av_packet_free(&packet); values.clear(); }
};

struct EnhancementDecoder {
  AVCodecContext* context = nullptr;
  AVRational time_base{1, 1000000};
  std::deque<AVFrame*> frames;
  std::mutex mutex;
  int nal_length_size = 0;
  std::atomic<bool> enabled{false};
  bool dual = false;
  bool flushed = false;

  ~EnhancementDecoder() { Reset(); }
  void Reset() {
    std::lock_guard lock(mutex);
    ClearFrames();
    avcodec_free_context(&context);
    enabled = false;
    dual = false;
    flushed = false;
  }
  void Configure(bool profile7_el, bool dual_stream, int nal_length, AVRational base_time) {
    std::lock_guard lock(mutex);
    enabled = profile7_el;
    dual = dual_stream && context != nullptr;
    nal_length_size = nal_length;
    if (!dual) time_base = base_time.num > 0 && base_time.den > 0 ? base_time : AVRational{1, 1000000};
    flushed = false;
  }
  bool OpenDual(AVFormatContext* format, int index);
  void Flush() {
    std::lock_guard lock(mutex);
    ClearFrames();
    flushed = false;
    if (context) avcodec_flush_buffers(context);
  }
  void Feed(AVPacket* packet);
  AVFrame* Take(int64_t pts_us);

 private:
  void ClearFrames() {
    for (auto*& frame : frames) av_frame_free(&frame);
    frames.clear();
  }
  bool EnsureOpen();
  bool ReceiveOne();
  void ReceiveAll() {
    while (ReceiveOne()) {}
  }
};

// core_decoder.cpp
AVHWDeviceType hardware_device_type(RillightCoreHardware hardware);
const char *mediacodec_decoder_name(AVCodecID codec);
AVPixelFormat choose_hardware_format(AVCodecContext *context,
                                     const AVPixelFormat *formats);
AVPixelFormat choose_software_format(AVCodecContext *,
                                     const AVPixelFormat *formats);
int software_thread_budget();
std::string truncate_for_diagnostics(const std::string &value, size_t limit);
#if defined(_WIN32)
std::string d3d11_adapter_name(IDXGIAdapter *adapter);
std::string d3d11_decode_gap(ID3D11Device *device, AVCodecID codec,
                             int profile, int pixel_format);
int create_attached_d3d11_hwdevice(AVBufferRef **out, IDXGIAdapter *adapter,
                                   AVCodecID codec, int profile,
                                   int pixel_format, std::string *diagnostics);
#endif
Decoder make_decoder(AVFormatContext *format, int index,
                     RillightCoreHardware preference = RILLIGHT_CORE_HW_NONE,
                     bool allow_software_fallback = true,
                     const std::shared_ptr<void>& android_window = {},
                     uint32_t android_dovi_profiles = 0,
                     int64_t discard_before_us = -1,
                     bool dovi_8bit = false,
                     const std::shared_ptr<AndroidTunnelFactory>& tunnel_factory = {},
                     uint32_t tunnel_profiles = 0,
                     void *windows_dxgi_adapter = nullptr);
int find_fel_stream(AVFormatContext* format, int base);
int restore_dovi_configuration(AVFormatContext* format, int index,
                               PendingPackets* pending);
}  // namespace rillight::core
