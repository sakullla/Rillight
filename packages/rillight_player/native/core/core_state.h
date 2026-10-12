#pragma once

#include "core_io.h"
#include "core_subtitles.h"

namespace rillight::core {
struct RillightCoreImpl {
  explicit RillightCoreImpl(const RillightCoreIo &source_io) : io(source_io) {}
  RillightCoreIo io;
  std::unique_ptr<LoopbackIo> owned_loopback;
  std::mutex mutex;
  std::mutex lifecycle_mutex;
  std::mutex subtitle_mutex;
  AssRenderer ass;
  AssRenderer secondary_ass;
  std::vector<SubtitleCue> secondary_cues;
  std::vector<SubtitleCue> subtitle_cues;
  BitmapSubtitleOverlayCache bitmap_subtitle_cache;
  RillightCoreSubtitlePresentation subtitle_presentation{};
  RillightCoreFrame *displayed_clean = nullptr;
  bool subtitle_redraw = false;
  RillightCoreFrame *subtitle_preview = nullptr;
  std::condition_variable wake;
  std::thread worker;
  std::thread subtitle_loader;
  std::atomic<bool> stop{false};
  std::atomic<bool> decode_abort{false};
  std::atomic<int> decode_error{0};
  std::atomic<uint64_t> timeline_signal{0};
  std::atomic<uint64_t> active_read_timeline{0};
  std::atomic<int> io_fatal_error{0};
  bool media_io_active = false;
  uint64_t session = 0;
  uint64_t operation = 0;
  uint64_t timeline = 0;
  RillightCoreState state = RILLIGHT_CORE_IDLE;
  bool play_intent = true;
  bool first_video = false;
  bool first_audio = false;
  // Video lane progress for the current timeline. Seek recovery uses this to
  // decide whether a full audio queue can wait for a picture.
  int video_packets_pending = 0;
  bool video_decode_busy = false;
  bool eof = false;
  bool input_exhausted = false;
  bool output_drained = false;
  int error = 0;
  int video_index = -1;
  int output_width = 0;
  int output_height = 0;
  bool gpu_video = false;
  bool hdr_video = false;
  bool macos_edr = false;
  bool android_color_buffers = false;
  bool android_native_dolby = false;
  double video_frame_rate = 0;
  bool software_video_required = false;
  uint64_t presentation_failure_timeline = 0;
  int presentation_failures = 0;
  int audio_index = -1;
  bool is_mp4_container = false;
  int video_track_id = -1;
  int audio_track_id = -1;
  int subtitle_index = -1;
  int secondary_subtitle_index = -1;
  int requested_subtitle_slot = 0;
  int requested_audio = -1;
  bool audio_change = false;
  int requested_subtitle = -1;
  bool subtitle_change = false;
  bool subtitle_selection_pending = false;
  bool external_subtitle_pending = false;
  std::string requested_external_subtitle;
  int64_t seek_target = -1;
  int64_t presentation_floor_us = 0;
  int64_t duration = -1;
  // Absolute PTS of the first sample, in microseconds. Frame clocks and the
  // seek bar are media time, so this origin is subtracted from PTS and added
  // only when calling av_seek_frame. MPEG-TS and HLS often start far from 0.
  int64_t media_origin_us = 0;
  int64_t base_position = 0;
  Clock::time_point base_time = Clock::now();
  bool audio_clock_active = false;
  int64_t audio_clock_limit = 0;
  bool audio_clock_handed_off = false;
  bool paused_video_frame_emitted = false;
  std::deque<RillightCoreFrame *> video;
  std::deque<RillightCoreFrame *> audio;
  std::vector<RillightCoreTrack> tracks;
#if RILLIGHT_HAVE_LIBASS
  std::vector<ExternalSubtitle> external_subtitles;
  size_t external_subtitle_bytes = 0;
  size_t embedded_stream_count = 0;
#endif
  double speed = 1.0;
  int sink_max_channels = 2;
  uint32_t sink_accept = 0;
  int sink_atmos = 0;
  uint64_t sink_generation = 0;
  int dolby_vision_profile = RILLIGHT_CORE_DOVI_PROFILE_UNKNOWN;
  int dolby_vision_compatibility = -1;
  int dovi_reconstruction = RILLIGHT_CORE_DOVI_RECON_NONE;
  int video_output_kind = RILLIGHT_CORE_VIDEO_OUT_UNKNOWN;
  int audio_delivery = RILLIGHT_CORE_AUDIO_DELIVERY_NONE;
  int audio_channels = 0;
  int audio_layout = RILLIGHT_CORE_CH_LAYOUT_NONE;
  int audio_atmos = 0;
  int audio_codec_id = 0;
  double volume = 1.0;
  bool external_audio_speed = false;
  double requested_speed = 1.0;
  bool speed_change = false;
  RillightCoreHardware hardware_preference = RILLIGHT_CORE_HW_NONE;
  std::shared_ptr<void> android_window;
  std::atomic<uint32_t> android_dovi_profiles{0};
  std::shared_ptr<AndroidTunnelFactory> tunnel_factory;
  std::shared_ptr<TunnelDecoder> tunnel;
  uint32_t tunnel_profiles = 0;
  bool tunnel_disabled = false;
  bool allow_software_fallback = true;
#if defined(_WIN32)
  // Presenter adapter reference held for same-adapter decode negotiation.
  IDXGIAdapter *dxgi_adapter = nullptr;
#endif
  // Guarded by mutex. Remote triage strings surfaced through the snapshot.
  std::string decode_diagnostics;
  std::string source_diagnostics;
  std::string source_format_name;
  VideoProcessingDiagnostics video_processing;
  size_t video_bytes = 0;
  size_t audio_bytes = 0;
  std::string url;
};

// core_state.cpp
int64_t playback_position(const RillightCoreImpl *core,
                          Clock::time_point now = Clock::now());
RillightCoreImpl *impl(RillightCore *core);
void clear_queue(std::deque<RillightCoreFrame *> &queue, size_t &bytes);
void drop_passthrough_frames(RillightCoreImpl *core);
bool unity_speed(double speed);
bool passthrough_still_wanted(const RillightCoreImpl *core,
                              const RillightCoreFrame *frame);
void reset_frames(RillightCoreImpl *core);
bool accept_operation(RillightCoreImpl *core, uint64_t operation);
void update_decode_diagnostics(RillightCoreImpl *core, Decoder &decoder,
                               const AVFrame *frame);
int enqueue(RillightCoreImpl *core, RillightCoreFrame *frame,
             int video_index, uint64_t timeline);
}  // namespace rillight::core
