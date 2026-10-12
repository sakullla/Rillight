#pragma once

#include "core_decoder.h"

namespace rillight::core {
struct VideoScale {
  // A rejected hardware texture mapping retries through downloaded planes for
  // this open. Do not repeatedly hit a known-incompatible interop path.
  bool hardware_color_failed = false;
  PortableColorPipeline portable_color_pipeline;
  EnhancementDecoder enhancement;
#if defined(_WIN32)
  WindowsColorPipeline color_pipeline;
#endif
  SwsContext *context = nullptr;
  std::shared_ptr<VideoBufferPool> buffers = std::make_shared<VideoBufferPool>();
  AVFrame *downloaded = nullptr;
  AVBufferRef *download_context = nullptr;
  ~VideoScale() {
    sws_free_context(&context);
    buffers->Release();
    av_frame_free(&downloaded);
    av_buffer_unref(&download_context);
  }
};

struct VideoOutputFrame : RillightCoreFrame {
  const char* color_path = "native";
  std::shared_ptr<VideoBufferPool> buffers;
  std::shared_ptr<void> gpu_texture;
  std::shared_ptr<AVFrame> codec_frame;
  int dovi_reconstruction = RILLIGHT_CORE_DOVI_RECON_NONE;
  int64_t presentation_time_ns = 0;
  bool subtitle_redraw = false;
  std::shared_ptr<std::vector<uint8_t>> subtitle_pixels;
  RillightCoreSubtitleOverlay subtitle_overlay{};
};

struct BitmapSubtitleOverlayCache {
  bool valid = false;
  BitmapSubtitleKey key{};
  std::shared_ptr<std::vector<uint8_t>> pixels;
  RillightCoreSubtitleOverlay overlay{};
};

struct AudioFilter {
  AVFilterGraph *graph = nullptr;
  AVFilterContext *source = nullptr;
  AVFilterContext *sink = nullptr;
  int input_rate = 0;
  AVSampleFormat input_format = AV_SAMPLE_FMT_NONE;
  AVChannelLayout input_layout{};
  double speed = 1.0;
  int64_t media_anchor = AV_NOPTS_VALUE;
  int64_t output_anchor = AV_NOPTS_VALUE;
  int64_t next_media_pts = AV_NOPTS_VALUE;
  int output_channels = 2;
  int output_layout = RILLIGHT_CORE_CH_LAYOUT_STEREO;
  int output_delivery = RILLIGHT_CORE_AUDIO_DELIVERY_PCM_STEREO;
  uint64_t sink_generation = 0;
};

struct AudioSinkView {
  int max_channels;
  uint32_t accept;
  int atmos;
  double speed;
  uint64_t generation;
};

using VideoSink = std::function<int(AVFrame *, int, uint32_t, uint64_t)>;
}  // namespace rillight::core
