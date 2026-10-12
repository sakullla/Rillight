#include "core_internal.h"

using namespace rillight::core;

#if defined(_WIN32)
#define RILLIGHT_DOVI_TEST_API __declspec(dllexport)
#else
#define RILLIGHT_DOVI_TEST_API __attribute__((visibility("default")))
#endif

namespace {
double srgb_encode(double linear) {
  if (linear <= 0) return 0;
  if (linear >= 1) return 1;
  if (linear <= 0.0031308) return 12.92 * linear;
  return 1.055 * std::pow(linear, 1.0 / 2.4) - 0.055;
}

double pq_nits(double code) {
  constexpr double m1 = 0.1593017578125;
  constexpr double m2 = 78.84375;
  constexpr double c1 = 0.8359375;
  constexpr double c2 = 18.8515625;
  constexpr double c3 = 18.6875;
  const double vp = std::pow(std::clamp(code, 0.0, 1.0), 1.0 / m2);
  const double num = std::max(vp - c1, 0.0);
  const double den = std::max(c2 - c3 * vp, 1e-9);
  return 10000.0 * std::pow(num / den, 1.0 / m1);
}

double hlg_nits(double code) {
  constexpr double a = 0.17883277;
  constexpr double b = 0.28466892;
  constexpr double c = 0.55991073;
  const double e = std::clamp(code, 0.0, 1.0);
  const double scene = e <= 0.5 ? (e * e) / 3.0
                                 : (std::exp((e - c) / a) + b) / 12.0;
  return scene * 1000.0;
}

double display_linear(double nits) {
  constexpr double white = 203.0;
  constexpr double peak = 1000.0;
  return std::clamp(nits * (1.0 + white / peak) / (white + nits), 0.0, 1.0);
}
}  // namespace

int rillight_core_android_tunnel_factory(RillightCore* pointer,
    std::shared_ptr<AndroidTunnelFactory> factory, uint32_t profiles) {
  if (!pointer) return -1;
  auto* core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (core->state != RILLIGHT_CORE_IDLE) return -1;
  core->tunnel_factory = std::move(factory);
  core->tunnel_profiles = profiles;
  return 0;
}

RILLIGHT_DOVI_TEST_API int rillight_dovi_base_rejected(int profile,
                                                       int compatibility) {
  if (profile < 0) return 0;
  // Profile 5 is IPT with no base. Compatibility 1 and 6 are HDR10
  // (Profile 7 uses 6), 2 is SDR, and 4 is HLG.
  if (profile == 5) return 1;
  return compatibility != 1 && compatibility != 2 && compatibility != 4 &&
         compatibility != 6;
}

RILLIGHT_DOVI_TEST_API int rillight_dovi_open_rejected(
    int profile, int compatibility, int el_present) {
  return dovi_open_rejected(profile, compatibility, el_present);
}

RILLIGHT_DOVI_TEST_API int rillight_dovi_frame_error(
    int profile, int compatibility, int el_present, int rpu_usable,
    int residual, int composed) {
  return dovi_frame_decision(profile, compatibility, el_present, rpu_usable,
                             residual, composed).error;
}

RILLIGHT_DOVI_TEST_API int rillight_dovi_frame_reconstruction(
    int profile, int compatibility, int el_present, int rpu_usable,
    int residual, int composed) {
  return dovi_frame_decision(profile, compatibility, el_present, rpu_usable,
                             residual, composed).reconstruction;
}

RILLIGHT_DOVI_TEST_API int rillight_dovi_frame_emits(
    int profile, int compatibility, int el_present, int rpu_usable,
    int residual, int composed) {
  return dovi_frame_decision(profile, compatibility, el_present, rpu_usable,
                             residual, composed).emit_picture;
}

RILLIGHT_DOVI_TEST_API int rillight_present_output_kind(
    int frame_type, int windows_scrgb, int macos_edr, int android_dolby_mime) {
  return dovi_present_output_kind(frame_type, windows_scrgb, macos_edr,
                                  android_dolby_mime);
}

RILLIGHT_DOVI_TEST_API int rillight_android_color_output_kind(
    int pq_selected) {
  return dovi_android_color_output_kind(pq_selected);
}

static const std::array<uint8_t, 256>& tonemap_lookup(int transfer) {
  static const auto tables = [] {
    std::array<std::array<uint8_t, 256>, 2> result{};
    for (int index = 0; index < 256; ++index) {
      const double unit = index / 255.0;
      result[0][index] = static_cast<uint8_t>(std::lround(
          255.0 * srgb_encode(display_linear(pq_nits(unit)))));
      result[1][index] = static_cast<uint8_t>(std::lround(
          255.0 * srgb_encode(display_linear(hlg_nits(unit)))));
    }
    return result;
  }();
  return tables[transfer == AVCOL_TRC_SMPTE2084 ? 0 : 1];
}

RILLIGHT_DOVI_TEST_API uint8_t rillight_tonemap_channel(int transfer,
                                                        uint8_t code) {
  if (transfer != AVCOL_TRC_SMPTE2084 && transfer != AVCOL_TRC_ARIB_STD_B67) {
    return code;
  }
  return tonemap_lookup(transfer)[code];
}

void tonemap_rgba(uint8_t *data, int stride, int width, int height,
                  int transfer) {
  if (transfer != AVCOL_TRC_SMPTE2084 && transfer != AVCOL_TRC_ARIB_STD_B67) {
    return;
  }
  // Resolve the initialized table once per frame, rather than entering the
  // one-time initialization guard for each channel of every HDR pixel.
  const auto& lookup = tonemap_lookup(transfer);
  for (int y = 0; y < height; ++y) {
    uint8_t *row = data + static_cast<ptrdiff_t>(y) * stride;
    for (int x = 0; x < width; ++x) {
      uint8_t *pixel = row + static_cast<ptrdiff_t>(x) * 4;
      pixel[0] = lookup[pixel[0]];
      pixel[1] = lookup[pixel[1]];
      pixel[2] = lookup[pixel[2]];
    }
  }
}

extern "C" {
uint32_t rillight_core_abi_version(void) { return RILLIGHT_CORE_ABI_VERSION; }

const char *rillight_core_ffmpeg_versions(void) {
  static const std::string versions =
      "ffmpeg=" + std::string(av_version_info()) +
      ";avformat=" + std::to_string(avformat_version()) +
      ";avcodec=" + std::to_string(avcodec_version()) +
      ";avutil=" + std::to_string(avutil_version());
  return versions.c_str();
}

RillightCore *rillight_core_create(const RillightCoreIo *io) {
  if (!io || !io->open || !io->read || !io->seek || !io->close ||
      !io->cancel_media_io) return nullptr;
  auto *core = new (std::nothrow) RillightCoreImpl(*io);
  return reinterpret_cast<RillightCore *>(core);
}

RillightCore *rillight_core_create_loopback(void) {
  auto owner = std::make_unique<LoopbackIo>();
  const RillightCoreIo io{owner.get(), loopback_open, loopback_read,
                          loopback_seek, loopback_close, loopback_cancel,
                          loopback_cancel_media};
  auto *core = rillight_core_create(&io);
  if (core) impl(core)->owned_loopback = std::move(owner);
  return core;
}

int rillight_core_configure_audio_sink(RillightCore *pointer,
                                        const RillightCoreAudioSink *sink) {
  if (!pointer || !sink || sink->struct_size != sizeof(*sink)) return -1;
  if (sink->max_pcm_channels < 1 || sink->max_pcm_channels > 8) return -1;
  if (sink->reports_atmos != 0 && sink->reports_atmos != 1) return -1;
  const uint32_t known = RILLIGHT_CORE_AUDIO_ACCEPT_EAC3 |
                         RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD |
                         RILLIGHT_CORE_AUDIO_ACCEPT_AC3 |
                         RILLIGHT_CORE_AUDIO_ACCEPT_DTS |
                         RILLIGHT_CORE_AUDIO_ACCEPT_DTSHD;
  if ((sink->accepted_passthrough & ~known) != 0) return -1;
  auto *core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (core->state == RILLIGHT_CORE_CLOSING) return -1;
  const bool changed = core->sink_max_channels != sink->max_pcm_channels ||
                       core->sink_accept != sink->accepted_passthrough ||
                       core->sink_atmos != sink->reports_atmos;
  core->sink_max_channels = sink->max_pcm_channels;
  core->sink_accept = sink->accepted_passthrough;
  core->sink_atmos = sink->reports_atmos;
  core->sink_generation++;
  if (changed) clear_queue(core->audio, core->audio_bytes);
  core->wake.notify_all();
  return 0;
}

int rillight_core_configure_external_audio_speed(RillightCore* pointer,
                                                int enabled) {
  if (!pointer || (enabled != 0 && enabled != 1)) return -1;
  auto* core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (core->state != RILLIGHT_CORE_IDLE) return -1;
  core->external_audio_speed = enabled != 0;
  return 0;
}

void rillight_core_destroy_loopback(RillightCore *core) {
  rillight_core_destroy(core);
}

int rillight_core_set_video_output_size(RillightCore *pointer,
                                        int width, int height) {
  if (!pointer || width < 0 || height < 0 || width > 8192 || height > 8192 ||
      ((width == 0) != (height == 0))) return -1;
  auto* core = impl(pointer);
  std::lock_guard lock(core->mutex);
  core->output_width = width;
  core->output_height = height;
  return 0;
}

int rillight_core_set_android_window(RillightCore* pointer, void* window,
                                    uint32_t dovi_profiles) {
#if defined(__ANDROID__)
  if (!pointer) return -1;
  auto* core = impl(pointer);
  std::lock_guard lock(core->mutex);
  core->android_dovi_profiles = dovi_profiles;
  if (core->android_window.get() == window) return 0;
  std::shared_ptr<void> retained;
  if (window) {
    ANativeWindow_acquire(static_cast<ANativeWindow*>(window));
    retained = std::shared_ptr<void>(window, [](void* pointer) {
      ANativeWindow_release(static_cast<ANativeWindow*>(pointer));
    });
  }
  core->android_window = std::move(retained);
  if (core->android_color_buffers) {
    // P010 decoding has no Surface producer. Replacing only its EGL output
    // must preserve the decoder, queued frames, audio and current timeline;
    // seeking back to a long GOP here caused several seconds of black output.
    core->wake.notify_all();
    return 0;
  }
  if (core->state == RILLIGHT_CORE_IDLE || core->state == RILLIGHT_CORE_OPENING ||
      core->state == RILLIGHT_CORE_ENDED || core->state == RILLIGHT_CORE_FAILED) return 0;
  const int64_t position = playback_position(core);
  ++core->timeline;
  core->timeline_signal = core->timeline;
  reset_frames(core);
  core->base_position = position;
  core->base_time = Clock::now();
  core->state = RILLIGHT_CORE_RECOVERING;
  core->seek_target = position;
  core->io.cancel_media_io(core->io.opaque);
  core->wake.notify_all();
  return 0;
#else
  (void)pointer;
  (void)window;
  (void)dovi_profiles;
  return -1;
#endif
}

int rillight_core_report_android_presentation(RillightCore* pointer,
                                             const RillightCoreFrame* frame,
                                             int succeeded) {
  if (!pointer || !frame) return -1;
  auto* core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (core->stop || core->session != frame->session_id ||
      core->timeline != frame->timeline_version ||
      core->software_video_required || !core->allow_software_fallback ||
      core->hardware_preference != RILLIGHT_CORE_HW_MEDIACODEC ||
      (frame->type != RILLIGHT_CORE_VIDEO_MEDIACODEC &&
       frame->type != RILLIGHT_CORE_VIDEO_ANDROID_P010)) return 0;
  if (core->presentation_failure_timeline != core->timeline) {
    core->presentation_failure_timeline = core->timeline;
    core->presentation_failures = 0;
  }
  if (succeeded) { core->presentation_failures = 0; return 0; }
  if (++core->presentation_failures < 3) return 0;
  // A decoder can succeed while image import, acquisition or GPU presentation
  // fails. Recover on the demux owner after all lanes have quiesced, just as for
  // decode failures; never feed an arbitrary inter frame to the new decoder.
  core->software_video_required = true;
  const int64_t position = playback_position(core);
  ++core->timeline;
  core->timeline_signal = core->timeline;
  reset_frames(core);
  core->seek_target = position;
  core->base_position = position;
  core->base_time = Clock::now();
  core->state = RILLIGHT_CORE_RECOVERING;
  core->wake.notify_all();
  core->io.cancel_media_io(core->io.opaque);
  return 1;
}

int rillight_core_render_mediacodec_frame(const RillightCoreFrame* frame) {
#if defined(__ANDROID__)
  if (!frame || frame->type != RILLIGHT_CORE_VIDEO_MEDIACODEC) return -1;
  if (static_cast<const VideoOutputFrame*>(frame)->subtitle_redraw) return 0;
  const auto& decoded = static_cast<const VideoOutputFrame*>(frame)->codec_frame;
  if (!decoded || !decoded->data[3]) return -1;
  // take_frame already schedules against the audio/media clock. SurfaceFlinger
  // expects an absolute CLOCK_MONOTONIC timestamp, not the stream's PTS (which
  // may start hours from zero after a resume). The boolean release API passes
  // that media timestamp through on some codecs and breaks display pacing.
  const auto now_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
      Clock::now().time_since_epoch()).count();
  const auto present_ns = std::max<int64_t>(now_ns,
      static_cast<const VideoOutputFrame*>(frame)->presentation_time_ns);
  return av_mediacodec_render_buffer_at_time(
      reinterpret_cast<AVMediaCodecBuffer*>(decoded->data[3]), present_ns);
#else
  (void)frame;
  return -1;
#endif
}

#if defined(__ANDROID__)
namespace {
thread_local std::unique_ptr<AndroidColorPipeline> android_color_renderer;
}
#endif

int rillight_core_render_android_color_frame(const RillightCoreFrame* frame,
                                            void* native_window,
                                            int hdr_display_supported,
                                            RillightCore* core_pointer) {
#if defined(__ANDROID__)
  if (!frame || !native_window || frame->type != RILLIGHT_CORE_VIDEO_ANDROID_P010) return -1;
  const auto& decoded = static_cast<const VideoOutputFrame*>(frame)->codec_frame;
  if (!decoded) return -1;
  if (!android_color_renderer) android_color_renderer = std::make_unique<AndroidColorPipeline>();
  const auto started = Clock::now();
  if (!android_color_renderer->Render(decoded.get(), static_cast<ANativeWindow*>(native_window),
                                      hdr_display_supported != 0))
    return -1;
  if (core_pointer) {
    auto* core = impl(core_pointer);
    std::lock_guard lock(core->mutex);
    if (core->session != frame->session_id || core->timeline != frame->timeline_version || core->stop)
      return 0;
    // This is output-thread submission (including any swap/backpressure), not
    // GPU execution time. The earlier frame-wrapper cost does not measure it.
    core->video_processing.Record(android_color_renderer->Path(), false,
        std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - started).count(),
        "submit");
    core->video_output_kind = dovi_android_color_output_kind(
        android_color_renderer->HdrPresented() ? 1 : 0);
    core->dovi_reconstruction = RILLIGHT_CORE_DOVI_RECON_RPU;
  }
  return 0;
#else
  (void)frame; (void)native_window; (void)hdr_display_supported; (void)core_pointer;
  return -1;
#endif
}

void rillight_core_release_android_color_renderer(void) {
#if defined(__ANDROID__)
  android_color_renderer.reset();
#endif
}

double rillight_core_video_frame_rate(RillightCore* pointer) {
  if (!pointer) return 0;
  auto* core = impl(pointer);
  std::lock_guard lock(core->mutex);
  return core->video_frame_rate;
}

double rillight_core_output_frame_rate(RillightCore* pointer) {
  if (!pointer) return 0;
  auto* core = impl(pointer);
  std::lock_guard lock(core->mutex);
  return core->video_frame_rate;
}

// ABI 10 compatibility only. Picture enhancement is no longer supported.
int rillight_core_configure_enhancement(
    RillightCore* pointer, const RillightCoreEnhancementRequest* request) {
  if (!pointer || !request || request->struct_size != sizeof(*request)) return -1;
  return request->interpolation || request->anime4k || request->super_resolution ||
      request->denoise || request->sharpen || request->accept_leave_native_dolby ? -1 : 0;
}
int rillight_core_retry_enhancement(
    RillightCore* pointer, const RillightCoreEnhancementRequest* request) {
  return rillight_core_configure_enhancement(pointer, request);
}
int rillight_core_note_frame_deadline(RillightCore* pointer, int met,
                                     int64_t monotonic_us) {
  return pointer && (met == 0 || met == 1) && monotonic_us >= 0 ? 0 : -1;
}
int rillight_core_enhancement_status(RillightCore* pointer,
                                    RillightCoreEnhancementStatus* status) {
  if (!pointer || !status || status->struct_size < sizeof(*status)) return -1;
  *status = {};
  status->struct_size = sizeof(*status);
  status->source_frame_rate = rillight_core_video_frame_rate(pointer);
  status->output_frame_rate = status->source_frame_rate;
  return 0;
}

int rillight_core_configure_hardware(RillightCore *pointer,
                                      RillightCoreHardware preference,
                                      int allow_software_fallback) {
  if (!pointer || (preference != RILLIGHT_CORE_HW_NONE &&
                   preference != RILLIGHT_CORE_HW_D3D11 &&
                   preference != RILLIGHT_CORE_HW_VIDEOTOOLBOX &&
                   preference != RILLIGHT_CORE_HW_VAAPI &&
                   preference != RILLIGHT_CORE_HW_MEDIACODEC))
    return -1;
  auto *core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (core->state != RILLIGHT_CORE_IDLE &&
      core->state != RILLIGHT_CORE_ENDED &&
      core->state != RILLIGHT_CORE_FAILED)
    return -1;
  core->hardware_preference = preference;
  core->allow_software_fallback = allow_software_fallback != 0;
  return 0;
}

int rillight_core_attach_d3d11_adapter(RillightCore *pointer,
                                       void *dxgi_adapter) {
#if defined(_WIN32)
  if (!pointer) return -1;
  auto *core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (core->state != RILLIGHT_CORE_IDLE &&
      core->state != RILLIGHT_CORE_ENDED &&
      core->state != RILLIGHT_CORE_FAILED)
    return -1;
  auto *next = static_cast<IDXGIAdapter *>(dxgi_adapter);
  if (next) next->AddRef();
  if (core->dxgi_adapter) core->dxgi_adapter->Release();
  core->dxgi_adapter = next;
  return 0;
#else
  (void)pointer;
  (void)dxgi_adapter;
  return -1;
#endif
}

void rillight_core_destroy(RillightCore *pointer) {
  if (!pointer) return;
  auto *core = impl(pointer);
  {
    std::lock_guard lifecycle(core->lifecycle_mutex);
    {
      std::lock_guard lock(core->mutex);
      core->state = RILLIGHT_CORE_CLOSING;
    }
    stop_worker(core);
    clear_queue(core->video, core->video_bytes);
    clear_queue(core->audio, core->audio_bytes);
    rillight_core_release_frame(core->displayed_clean);
    rillight_core_release_frame(core->subtitle_preview);
    close_ass(&core->ass);
    close_ass(&core->secondary_ass);
#if defined(_WIN32)
    if (core->dxgi_adapter) {
      core->dxgi_adapter->Release();
      core->dxgi_adapter = nullptr;
    }
#endif
  }
  delete core;
}

int rillight_core_configure_gpu_video(RillightCore *pointer, int enabled) {
  if (!pointer) return -1;
  auto* core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (!enabled) { core->gpu_video = false; core->hdr_video = false; return 0; }
  if (core->state != RILLIGHT_CORE_IDLE && core->state != RILLIGHT_CORE_ENDED &&
      core->state != RILLIGHT_CORE_FAILED) return -1;
#if defined(_WIN32) || defined(RILLIGHT_HAVE_MACOS_COLOR)
  core->gpu_video = enabled != 0;
  return 0;
#else
  return enabled ? -1 : 0;
#endif
}

void* rillight_core_frame_macos_buffer(const RillightCoreFrame* frame) {
  if (!frame || (frame->type != RILLIGHT_CORE_VIDEO_MACOS_BUFFER &&
                 frame->type != RILLIGHT_CORE_VIDEO_MACOS_LINEAR)) return nullptr;
  return static_cast<const VideoOutputFrame*>(frame)->gpu_texture.get();
}

void* rillight_core_frame_d3d11_texture(const RillightCoreFrame* frame) {
  if (!frame || frame->type != RILLIGHT_CORE_VIDEO_D3D11) return nullptr;
  return static_cast<const VideoOutputFrame*>(frame)->gpu_texture.get();
}

int rillight_core_configure_hdr_video(RillightCore* pointer, int enabled) {
  if (!pointer) return -1;
  auto* core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (!enabled) { core->hdr_video = false; return 0; }
#if defined(_WIN32)
  if (!core->gpu_video || (core->state != RILLIGHT_CORE_IDLE &&
      core->state != RILLIGHT_CORE_ENDED && core->state != RILLIGHT_CORE_FAILED)) return -1;
  core->hdr_video = true;
  return 0;
#else
  return -1;
#endif
}

int rillight_core_configure_macos_edr(RillightCore* pointer, int enabled) {
  if (!pointer) return -1;
  auto* core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (core->state != RILLIGHT_CORE_IDLE && core->state != RILLIGHT_CORE_ENDED &&
      core->state != RILLIGHT_CORE_FAILED) return -1;
  core->macos_edr = enabled != 0;
  return 0;
}

int rillight_core_frame_subtitle_overlay(const RillightCoreFrame* frame,
                                        RillightCoreSubtitleOverlay* overlay) {
  if (!frame || !overlay || overlay->struct_size < sizeof(*overlay) ||
      (frame->type != RILLIGHT_CORE_VIDEO_D3D11 &&
       frame->type != RILLIGHT_CORE_VIDEO_MEDIACODEC &&
       frame->type != RILLIGHT_CORE_VIDEO_ANDROID_P010 &&
       frame->type != RILLIGHT_CORE_VIDEO_MACOS_BUFFER &&
       frame->type != RILLIGHT_CORE_VIDEO_MACOS_LINEAR &&
       frame->type != RILLIGHT_CORE_VIDEO_RGBA16F)) return -1;
  *overlay = static_cast<const VideoOutputFrame*>(frame)->subtitle_overlay;
  overlay->struct_size = sizeof(*overlay);
  return 0;
}

int rillight_core_open(RillightCore *pointer, const char *url,
                       uint64_t operation_id) {
  return rillight_core_open_at(pointer, url, 0, operation_id);
}

int rillight_core_open_at(RillightCore *pointer, const char *url,
                          int64_t position_us, uint64_t operation_id) {
  if (!pointer || !url || !*url || position_us < 0) return -1;
  auto *core = impl(pointer);
  std::lock_guard lifecycle(core->lifecycle_mutex);
  {
    std::lock_guard lock(core->mutex);
    if (!accept_operation(core, operation_id)) return -1;
    core->state = RILLIGHT_CORE_CLOSING;
  }
  stop_worker(core);
  {
    std::lock_guard lock(core->mutex);
    reset_frames(core);
    { std::lock_guard subtitle_lock(core->subtitle_mutex); close_ass(&core->ass); close_ass(&core->secondary_ass);
      core->secondary_cues.clear(); }
    core->stop = false;
    core->decode_abort = false;
    core->decode_error = 0;
    core->media_io_active = false;
    ++core->session;
    core->subtitle_presentation = {};
    ++core->timeline;
    core->timeline_signal = core->timeline;
    core->url = url;
    core->decode_diagnostics.clear();
    core->source_diagnostics.clear();
    core->source_format_name.clear();
    core->video_index = core->audio_index = core->subtitle_index = -1;
    core->secondary_subtitle_index = -1;
    core->requested_subtitle_slot = 0;
    core->video_frame_rate = 0;
    core->android_color_buffers = false;
    core->android_native_dolby = false;


    core->dolby_vision_profile = RILLIGHT_CORE_DOVI_PROFILE_UNKNOWN;
    core->dolby_vision_compatibility = -1;
    core->dovi_reconstruction = RILLIGHT_CORE_DOVI_RECON_NONE;
    core->video_output_kind = RILLIGHT_CORE_VIDEO_OUT_UNKNOWN;
    core->is_mp4_container = false;
    core->software_video_required = false;
    core->presentation_failure_timeline = 0;
    core->presentation_failures = 0;
    core->video_track_id = core->audio_track_id = -1;
    core->duration = -1;
    core->media_origin_us = 0;
    core->base_position = position_us;
    core->base_time = Clock::now();
    core->seek_target = position_us > 0 ? position_us : -1;
    core->audio_change = false;
    core->requested_audio = -1;
    core->subtitle_change = false;
    core->subtitle_selection_pending = false;
    core->requested_subtitle = -1;
    core->external_subtitle_pending = false;
    core->requested_external_subtitle.clear();
    core->speed_change = false;
    core->tracks.clear();
#if RILLIGHT_HAVE_LIBASS
    core->external_subtitles.clear();
    core->external_subtitle_bytes = 0;
    core->embedded_stream_count = 0;
#endif
    core->error = 0;
    core->state = RILLIGHT_CORE_OPENING;
  }
  core->worker = std::thread(run, core, core->session);
  return 0;
}

int rillight_core_set_playing(RillightCore *pointer, int playing,
                              uint64_t operation_id) {
  if (!pointer) return -1;
  auto *core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (!accept_operation(core, operation_id)) return -1;
  if (core->state == RILLIGHT_CORE_IDLE ||
      core->state == RILLIGHT_CORE_ENDED ||
      core->state == RILLIGHT_CORE_FAILED) return -1;
  if (core->state == RILLIGHT_CORE_PLAYING && !playing)
    core->base_position = playback_position(core);
  core->play_intent = playing != 0;
  if (core->state == RILLIGHT_CORE_PLAYING ||
      core->state == RILLIGHT_CORE_PAUSED || core->state == RILLIGHT_CORE_READY) {
    core->state = playing ? RILLIGHT_CORE_PLAYING : RILLIGHT_CORE_PAUSED;
    core->base_time = Clock::now();
  }
  core->wake.notify_all();
  return 0;
}

int rillight_core_seek(RillightCore *pointer, int64_t position_us,
                       uint64_t operation_id) {
  if (!pointer || position_us < 0) return -1;

  auto *core = impl(pointer);
  std::unique_lock lock(core->mutex);
  if (core->state == RILLIGHT_CORE_IDLE ||
      core->state == RILLIGHT_CORE_OPENING ||
      core->state == RILLIGHT_CORE_ENDED ||
      core->state == RILLIGHT_CORE_FAILED ||
      !accept_operation(core, operation_id)) return -1;
  ++core->timeline;
  core->timeline_signal = core->timeline;
  reset_frames(core);
  core->seek_target = position_us;
  core->base_position = position_us;
  core->base_time = Clock::now();
  core->state = RILLIGHT_CORE_RECOVERING;
  core->wake.notify_all();
  // The proxy may already have cancelled the old HTTP response while this
  // worker is paused (and no media read is active). Advance the loopback IO
  // generation on every seek so its next AVIO seek reopens the sealed route
  // rather than waiting on that stale connection.
  // The worker cannot start a new-timeline read until this callback returns.
  core->io.cancel_media_io(core->io.opaque);
  return 0;
}

int rillight_core_select_audio(RillightCore *pointer, int stream_index,
                                uint64_t operation_id) {
  if (!pointer || stream_index < 0) return -1;
  auto *core = impl(pointer);
  std::unique_lock lock(core->mutex);
  if (core->state == RILLIGHT_CORE_IDLE ||
      core->state == RILLIGHT_CORE_OPENING ||
      core->state == RILLIGHT_CORE_ENDED ||
      core->state == RILLIGHT_CORE_FAILED) return -1;
  if (std::none_of(core->tracks.begin(), core->tracks.end(),
                   [stream_index](const RillightCoreTrack &track) {
                     return track.type == RILLIGHT_CORE_TRACK_AUDIO &&
                            track.stream_index == stream_index &&
                            avcodec_find_decoder(
                                static_cast<AVCodecID>(track.codec_id));
                   })) return AVERROR_DECODER_NOT_FOUND;
  if (!accept_operation(core, operation_id)) return -1;
  if (core->audio_index == stream_index && !core->audio_change) return 0;
  core->error = 0;
  core->base_position = playback_position(core);
  core->requested_audio = stream_index;
  core->audio_change = true;
  ++core->timeline;
  core->timeline_signal = core->timeline;
  reset_frames(core);
  core->seek_target = core->base_position;
  core->base_time = Clock::now();
  core->state = RILLIGHT_CORE_RECOVERING;
  core->wake.notify_all();
  if (core->media_io_active)
    core->io.cancel_media_io(core->io.opaque);
  return 0;
}

static RillightCoreFrame *compose_displayed_frame(RillightCoreImpl *core, bool redraw);

int rillight_core_select_subtitle(RillightCore *pointer, int stream_index,
                                   uint64_t operation_id) {
  return rillight_core_select_subtitle_slot(pointer, 0, stream_index, operation_id);
}

int rillight_core_select_subtitle_slot(RillightCore *pointer, int slot, int stream_index,
                                   uint64_t operation_id) {
  if (!pointer || stream_index < -1 || slot < 0 || slot > 1) return -1;
  auto *core = impl(pointer);
  std::unique_lock lock(core->mutex);
  if (core->state == RILLIGHT_CORE_IDLE ||
      core->state == RILLIGHT_CORE_OPENING ||
      core->state == RILLIGHT_CORE_ENDED ||
      core->state == RILLIGHT_CORE_FAILED) return -1;
  if (stream_index != -1 &&
      std::none_of(core->tracks.begin(), core->tracks.end(),
                   [stream_index](const RillightCoreTrack &track) {
                     return track.type == RILLIGHT_CORE_TRACK_SUBTITLE &&
                            track.stream_index == stream_index;
                   })) return -1;
  // Commands share one demux transaction. Reject concurrent replacement rather
  // than losing a different slot's pending selection.
  if (core->subtitle_selection_pending) return -1;
  if (stream_index >= 0 && stream_index ==
      (slot == 1 ? core->subtitle_index : core->secondary_subtitle_index)) return -1;
  auto &selected_index = slot == 1 ? core->secondary_subtitle_index : core->subtitle_index;
  if (!accept_operation(core, operation_id)) return -1;
  if (selected_index == stream_index)
    return 0;
  if (core->input_exhausted) return -1;
  if (stream_index == -1 && !core->subtitle_change &&
      core->state != RILLIGHT_CORE_RECOVERING) {
    // Hiding captions needs no media seek or codec flush. Publish the choice
    // immediately, including while paused or waiting for network data; the
    // demux worker retires only the subtitle decoder at its next safe point.
    // The hide is not a demux transaction: a stalled read must not keep the
    // slot marked pending, and cues stay gated by the published index.
    selected_index = -1;
    core->requested_subtitle_slot = slot;
    core->requested_subtitle = -1;
    core->subtitle_change = true;
    core->subtitle_selection_pending = false;
    core->error = 0;
    if (core->displayed_clean) {
      rillight_core_release_frame(core->subtitle_preview);
      core->subtitle_preview = compose_displayed_frame(core, true);
      core->subtitle_redraw = core->subtitle_preview != nullptr;
    }
    core->wake.notify_all();
    return 0;
  }
  core->base_position = playback_position(core);
  core->requested_subtitle_slot = slot;
  core->requested_subtitle = stream_index;
  core->subtitle_change = true;
  core->subtitle_selection_pending = true;
  ++core->timeline;
  core->timeline_signal = core->timeline;
  reset_frames(core);
  core->seek_target = core->base_position;
  core->base_time = Clock::now();
  core->state = RILLIGHT_CORE_RECOVERING;
  core->wake.notify_all();
  if (core->media_io_active)
    core->io.cancel_media_io(core->io.opaque);
  return 0;
}

int rillight_core_add_external_subtitle(RillightCore *pointer,
                                        const char *url,
                                        uint64_t operation_id) {
#if RILLIGHT_HAVE_LIBASS
  if (!pointer || !url || !*url || std::strlen(url) > 2048) return -1;
  auto *core = impl(pointer);
  if (!core->io.cancel) return -1;
  std::lock_guard lifecycle(core->lifecycle_mutex);
  {
    std::lock_guard lock(core->mutex);
    if (core->external_subtitle_pending) return -1;
  }
  if (core->subtitle_loader.joinable()) core->subtitle_loader.join();
  std::lock_guard lock(core->mutex);
  if (core->state == RILLIGHT_CORE_IDLE ||
      core->state == RILLIGHT_CORE_OPENING ||
      core->state == RILLIGHT_CORE_ENDED ||
      core->state == RILLIGHT_CORE_FAILED ||
      core->input_exhausted ||
      !accept_operation(core, operation_id)) return -1;
  core->requested_external_subtitle = url;
  core->external_subtitle_pending = true;
  core->error = 0;
  try {
    core->subtitle_loader = std::thread(load_external_ass, core,
                                        core->session, std::string(url));
  } catch (...) {
    core->external_subtitle_pending = false;
    core->requested_external_subtitle.clear();
    core->error = AVERROR(ENOMEM);
    return -1;
  }
  return 0;
#else
  (void)pointer;
  (void)url;
  (void)operation_id;
  return -1;
#endif
}

int rillight_core_track_count(RillightCore *pointer) {
  if (!pointer) return -1;
  auto *core = impl(pointer);
  std::lock_guard lock(core->mutex);
  return static_cast<int>(core->tracks.size());
}

int rillight_core_set_speed(RillightCore *pointer, double speed,
                            uint64_t operation_id) {
  if (!pointer || !std::isfinite(speed) || speed < 0.5 || speed > 3.0)
    return -1;
  auto *core = impl(pointer);
  std::unique_lock lock(core->mutex);
  if (core->state == RILLIGHT_CORE_IDLE ||
      core->state == RILLIGHT_CORE_OPENING ||
      core->state == RILLIGHT_CORE_ENDED ||
      core->state == RILLIGHT_CORE_FAILED ||
      !accept_operation(core, operation_id)) return -1;
  // Restoring the default rate during startup must not tear down a healthy
  // read timeline and wait for another network open.
  if (core->requested_speed == speed) return 0;
  core->base_position = playback_position(core);
  core->requested_speed = speed;
  if (core->external_audio_speed) {
    // PCM already queued stays: AudioTrack retimes it. Compressed access
    // units cannot change rate, so drop them and let the next packet decode.
    if (!unity_speed(speed)) drop_passthrough_frames(core);
    core->speed = speed;
    core->base_time = Clock::now();
    core->wake.notify_all();
    return 0;
  }
  core->speed_change = true;
  ++core->timeline;
  core->timeline_signal = core->timeline;
  reset_frames(core);
  core->seek_target = core->base_position;
  core->base_time = Clock::now();
  core->state = RILLIGHT_CORE_RECOVERING;
  core->wake.notify_all();
  if (core->media_io_active)
    core->io.cancel_media_io(core->io.opaque);
  return 0;
}

int rillight_core_set_volume(RillightCore *pointer, double gain,
                             uint64_t operation_id) {
  if (!pointer || !std::isfinite(gain) || gain < 0.0 || gain > 1.5)
    return -1;
  auto *core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (core->state == RILLIGHT_CORE_IDLE ||
      core->state == RILLIGHT_CORE_CLOSING ||
      !accept_operation(core, operation_id)) return -1;
  const bool retire_encoded = core->volume == 1.0 && gain != 1.0 &&
      core->audio_delivery == RILLIGHT_CORE_AUDIO_DELIVERY_PASSTHROUGH &&
      core->state != RILLIGHT_CORE_ENDED && core->state != RILLIGHT_CORE_FAILED;
  core->volume = gain;
  if (retire_encoded) {
    // Retire device buffers too, including when paused or at demux EOF. Merely
    // dropping decoded-ahead access units would skip audio or leave no PCM.
    const int64_t position = playback_position(core);
    ++core->timeline;
    core->timeline_signal = core->timeline;
    reset_frames(core);
    core->seek_target = position;
    core->base_position = position;
    core->base_time = Clock::now();
    core->state = RILLIGHT_CORE_RECOVERING;
    core->io.cancel_media_io(core->io.opaque);
  } else if (gain != 1.0) {
    drop_passthrough_frames(core);
  }
  core->wake.notify_all();
  return 0;
}

int rillight_core_get_track(RillightCore *pointer, int ordinal,
                            RillightCoreTrack *track) {
  if (!pointer || !track || track->struct_size < sizeof(*track)) return -1;
  auto *core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (ordinal < 0 || ordinal >= static_cast<int>(core->tracks.size()))
    return -1;
  *track = core->tracks[ordinal];
  return 0;
}

int rillight_core_report_audio_played(RillightCore *pointer,
                                      uint64_t session_id,
                                      uint64_t timeline_version,
                                      int64_t queued_end_pts_us,
                                      int64_t remaining_media_delay_us) {
  if (!pointer || queued_end_pts_us < 0 || remaining_media_delay_us < 0)
    return -1;
  auto *core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (session_id != core->session || timeline_version != core->timeline)
    return -1;
  // Keep the seek target fixed until its video frame is decoded. Starting
  // the audio clock first moves that target while RGBA conversion is running,
  // so recovery can keep rejecting every video frame as preceding the target.
  if (core->state == RILLIGHT_CORE_RECOVERING && core->video_index >= 0 &&
      !core->first_video)
    return -1;
  const auto now = Clock::now();
  const int64_t current_position = playback_position(core, now);
  const int64_t reported_position =
      std::max<int64_t>(0, queued_end_pts_us - remaining_media_delay_us);
  if (core->audio_clock_handed_off && queued_end_pts_us <= current_position)
    return -1;
  core->audio_clock_active = true;
  core->audio_clock_limit = queued_end_pts_us;
  core->audio_clock_handed_off = false;
  core->base_position = std::max(current_position, reported_position);
  // A device presentation clock can lag the initial wall clock or report a
  // newly measured hardware latency. Hold video until audio catches up rather
  // than preserving that lead forever with max(current, reported) on every tick.
  // The public position stays monotonic while the clock corrects its phase.
  const auto catchup_us = static_cast<int64_t>(
      std::max<int64_t>(0, current_position - reported_position) / core->speed);
  core->base_time = now + std::chrono::microseconds(catchup_us);
  return 0;
}

int rillight_core_report_audio_unavailable(RillightCore *pointer,
                                           uint64_t session_id,
                                           uint64_t timeline_version) {
  if (!pointer) return -1;
  auto *core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (session_id != core->session || timeline_version != core->timeline)
    return -1;
  if (!core->audio_clock_active) return 0;
  core->base_position = playback_position(core);
  core->audio_clock_active = false;
  core->audio_clock_handed_off = true;
  core->base_time = Clock::now();
  return 0;
}

int rillight_core_report_output_drained(RillightCore *pointer,
                                         uint64_t session_id,
                                         uint64_t timeline_version) {
  if (!pointer) return -1;
  auto *core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (session_id != core->session || timeline_version != core->timeline)
    return -1;
  if (!core->eof) return -1;
  core->output_drained = true;
  core->wake.notify_all();
  return 0;
}

int rillight_core_snapshot(RillightCore *pointer,
                           RillightCoreSnapshot *snapshot) {
  if (!pointer || !snapshot || snapshot->struct_size < sizeof(*snapshot))
    return -1;
  auto *core = impl(pointer);
  std::lock_guard lock(core->mutex);
  snapshot->abi_version = RILLIGHT_CORE_ABI_VERSION;
  snapshot->session_id = core->session;
  snapshot->operation_id = core->operation;
  snapshot->timeline_version = core->timeline;
  snapshot->state = core->state;
  snapshot->ffmpeg_error = core->error;
  snapshot->video_stream_index = core->video_index;
  snapshot->audio_stream_index = core->audio_index;
  snapshot->subtitle_stream_index = core->subtitle_index;
  snapshot->secondary_subtitle_stream_index = core->secondary_subtitle_index;
  snapshot->subtitle_selection_pending = core->subtitle_selection_pending;
  snapshot->duration_us = core->duration;
  snapshot->position_us = playback_position(core);
  snapshot->first_video_frame_ready = core->first_video;
  snapshot->first_audio_frame_ready = core->first_audio;
  snapshot->source_eof = core->eof;
  snapshot->queued_video_frames = static_cast<int>(core->video.size());
  if (core->tunnel && core->tunnel->submitted > core->tunnel->emitted)
    ++snapshot->queued_video_frames;
  snapshot->queued_audio_frames = static_cast<int>(core->audio.size());
  snapshot->playback_speed = core->speed;
  snapshot->preferred_hardware = core->hardware_preference;
  snapshot->allow_software_fallback = core->allow_software_fallback;
  snapshot->external_subtitle_pending = core->external_subtitle_pending;
  snapshot->dolby_vision_profile = core->dolby_vision_profile;
  snapshot->dolby_vision_compatibility = core->dolby_vision_compatibility;
  snapshot->dovi_reconstruction = core->dovi_reconstruction;
  snapshot->video_output_kind = core->video_output_kind;
  snapshot->audio_delivery = core->audio_delivery;
  snapshot->audio_channels = core->audio_channels;
  snapshot->audio_layout = core->audio_layout;
  snapshot->audio_atmos = core->audio_atmos;
  snapshot->audio_codec_id = core->audio_codec_id;
  snapshot->requested_interpolation = 0;
  snapshot->effective_interpolation = 0;
  snapshot->requested_anime4k = 0;
  snapshot->effective_anime4k = 0;
  snapshot->requested_super_resolution = 0;
  snapshot->effective_super_resolution = 0;
  snapshot->requested_denoise = 0;
  snapshot->effective_denoise = 0;
  snapshot->requested_sharpen = 0;
  snapshot->effective_sharpen = 0;
  const std::string decode_details = core->video_processing.summary.empty()
      ? core->decode_diagnostics
      : truncate_for_diagnostics(core->decode_diagnostics, 96) + "; " +
        core->video_processing.summary;
  std::snprintf(snapshot->decode_diagnostics,
                sizeof(snapshot->decode_diagnostics), "%s",
                decode_details.c_str());
  std::snprintf(snapshot->source_diagnostics,
                sizeof(snapshot->source_diagnostics), "%s",
                core->source_diagnostics.c_str());

  return 0;
}

int rillight_core_container_track_ids(RillightCore *pointer,
                                      int *video_track_id,
                                      int *audio_track_id) {
  if (!pointer || !video_track_id || !audio_track_id) return -1;
  auto *core = impl(pointer);
  std::lock_guard lock(core->mutex);
  *video_track_id = core->video_track_id;
  *audio_track_id = core->audio_track_id;
  return 0;
}

int rillight_core_set_subtitle_presentation(RillightCore *pointer,
    const RillightCoreSubtitlePresentation *p, uint64_t session) {
  if (!pointer || !p || p->struct_size != sizeof(*p) || p->version != 1 ||
      (p->enabled != 0 && p->enabled != 1) ||
      (p->original_ass != 0 && p->original_ass != 1)) return -1;
  if (p->enabled && (!std::isfinite(p->display_width) ||
      !std::isfinite(p->display_height) || !std::isfinite(p->font_size) ||
      !std::isfinite(p->user_scale) || !std::isfinite(p->safe_horizontal) ||
      !std::isfinite(p->safe_vertical) || p->display_width < 1 ||
      p->display_height < 1 || p->display_width > 32768 ||
      p->display_height > 32768 || p->font_size < 1 || p->font_size > 512 ||
      p->user_scale < 0.25 || p->user_scale > 4 ||
      p->safe_horizontal < 0 || p->safe_vertical < 0 ||
      p->safe_horizontal * 2 >= p->display_width ||
      p->safe_vertical * 2 >= p->display_height)) return -1;
  auto *core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (!session || session != core->session || core->state == RILLIGHT_CORE_CLOSING)
    return -1;
  const auto previous = core->subtitle_presentation;
  core->subtitle_presentation = *p;
  if (core->displayed_clean) {
    auto *preview = compose_displayed_frame(core, true);
    if (!preview) {
      core->subtitle_presentation = previous;
      return -1;
    }
    rillight_core_release_frame(core->subtitle_preview);
    core->subtitle_preview = preview;
    core->subtitle_redraw = true;
  }
  return 0;
}

// The retained frame is never handed to a sink or blended. A redraw therefore
// cannot accumulate glyphs, mutate an outstanding texture, or advance time.
static VideoOutputFrame *subtitle_frame_copy(const RillightCoreFrame *source) {
  auto *copy = new (std::nothrow) VideoOutputFrame(
      *static_cast<const VideoOutputFrame *>(source));
  if (!copy) return nullptr;
  if (source->data) {
    copy->data = copy->buffers->Acquire(source->data_size);
    if (!copy->data) { delete copy; return nullptr; }
    memcpy(copy->data, source->data, source->data_size);
  }
  copy->subtitle_pixels.reset();
  copy->subtitle_overlay = {};
  return copy;
}

static RillightCoreFrame *compose_displayed_frame(RillightCoreImpl *core,
                                                  bool redraw) {
  VideoOutputFrame *frame = nullptr;
  try {
    frame = subtitle_frame_copy(core->displayed_clean);
    if (!frame) return nullptr;
    frame->subtitle_redraw = redraw;
    if (core->subtitle_index < 0 && core->secondary_subtitle_index < 0) return frame;
    std::lock_guard subtitle_lock(core->subtitle_mutex);
    core->subtitle_cues.erase(std::remove_if(core->subtitle_cues.begin(),
        core->subtitle_cues.end(), [frame](const SubtitleCue &cue) {
          return cue.end_us < frame->pts_us;
        }), core->subtitle_cues.end());
    core->secondary_cues.erase(std::remove_if(core->secondary_cues.begin(),
        core->secondary_cues.end(), [frame](const SubtitleCue &cue) {
          return cue.end_us < frame->pts_us;
        }), core->secondary_cues.end());
    const std::vector<SubtitleCue> empty_cues;
    const auto &cues = core->subtitle_index >= 0 ? core->subtitle_cues : empty_cues;
    const auto &secondary_cues = core->secondary_subtitle_index >= 0 ? core->secondary_cues : empty_cues;
    AssRenderer empty;
    auto *primary = core->subtitle_index >= 0 ? &core->ass : &empty;
    auto *secondary = core->secondary_subtitle_index >= 0 ? &core->secondary_ass : &empty;
    apply_subtitle_presentation(secondary, frame->width, frame->height,
                                core->subtitle_presentation);
    apply_subtitle_presentation(primary, frame->width, frame->height,
                                core->subtitle_presentation);
    if (frame->type == RILLIGHT_CORE_VIDEO_RGBA) {
      blend_subtitles(frame, cues);
      blend_subtitles(frame, secondary_cues);
      blend_ass(frame, primary);
      blend_ass(frame, secondary);
    } else {
      const int bytes = frame->data_size;
      render_gpu_subtitles(frame, cues, primary,
                           &core->bitmap_subtitle_cache, secondary, &secondary_cues);
      if (frame->data) frame->data_size = bytes;
    }
    return frame;
  } catch (const std::bad_alloc &) {
    rillight_core_release_frame(frame);
    return nullptr;
  }
}

RillightCoreFrame *rillight_core_take_frame(RillightCore *pointer, int type) {
  if (!pointer) return nullptr;
  auto *core = impl(pointer);
  std::lock_guard lock(core->mutex);
  const bool audio = rillight_core_frame_is_audio(type);
  if (!audio && type != RILLIGHT_CORE_VIDEO_RGBA && type != RILLIGHT_CORE_VIDEO_D3D11 &&
      type != RILLIGHT_CORE_VIDEO_MEDIACODEC && type != RILLIGHT_CORE_VIDEO_ANDROID_P010)
    return nullptr;
  if (audio && !core->tunnel &&
      core->state == RILLIGHT_CORE_RECOVERING && core->video_index >= 0 &&
      !core->first_video)
    return nullptr;
  if (!audio && core->tunnel) {
    auto tunnel = core->tunnel;
    std::shared_ptr<AndroidTunnelSink> sink;
    { std::lock_guard lock(tunnel->mutex); sink = tunnel->sink; }
    const int64_t pts = media_pts_us(core, sink ? sink->Rendered() : -1);
    if (pts >= tunnel->discard_before && pts > tunnel->emitted) {
      auto* receipt = new (std::nothrow) VideoOutputFrame{};
      if (!receipt) return nullptr;
      receipt->struct_size = sizeof(RillightCoreFrame);
      receipt->type = RILLIGHT_CORE_VIDEO_ANDROID_TUNNEL;
      receipt->session_id = core->session; receipt->timeline_version = core->timeline;
      receipt->pts_us = pts; receipt->width = tunnel->width; receipt->height = tunnel->height;
      receipt->sar_num = receipt->sar_den = 1;
      receipt->source_color_transfer = AVCOL_TRC_SMPTE2084;
      receipt->source_color_primaries = AVCOL_PRI_BT2020;
      tunnel->emitted = pts;
      core->first_video = true;
      core->video_output_kind = RILLIGHT_CORE_VIDEO_OUT_DOLBY_VISION;
      core->dovi_reconstruction = RILLIGHT_CORE_DOVI_RECON_NONE;
      for (auto& track : core->tracks)
        if (track.stream_index == core->video_index) track.actual_hardware = RILLIGHT_CORE_HW_MEDIACODEC;
      rillight_core_release_frame(core->displayed_clean);
      core->displayed_clean = receipt;
      core->wake.notify_all();
      return compose_displayed_frame(core, false);
    }
    if (!core->subtitle_redraw) return nullptr;
  }
  if (!audio && core->subtitle_redraw && core->displayed_clean) {
    auto *redraw = core->subtitle_preview;
    if (type == RILLIGHT_CORE_VIDEO_RGBA && redraw &&
        redraw->type != RILLIGHT_CORE_VIDEO_RGBA &&
        redraw->type != RILLIGHT_CORE_VIDEO_MACOS_BUFFER &&
       redraw->type != RILLIGHT_CORE_VIDEO_MACOS_LINEAR &&
       redraw->type != RILLIGHT_CORE_VIDEO_RGBA16F) return nullptr;
    core->subtitle_preview = nullptr;
    core->subtitle_redraw = false;
    return redraw;
  }
  auto &queue = audio ? core->audio : core->video;
  auto &bytes = audio ? core->audio_bytes : core->video_bytes;
  if (queue.empty()) {
    if (!audio && core->first_video &&
        core->audio_index >= 0 &&
        (core->audio_clock_active || core->audio_clock_handed_off) &&
        core->state == RILLIGHT_CORE_PLAYING && !core->eof &&
        core->audio.empty()) {
      const int64_t position = playback_position(core);
      if (core->audio_clock_handed_off || position >= core->audio_clock_limit) {
        // Both lanes are starved and the submitted PCM has drained. Freeze
        // at the consumed endpoint until enqueue() resumes this timeline.
        core->base_position = position;
        core->base_time = Clock::now();
        core->state = RILLIGHT_CORE_BUFFERING;
      }
    }
    return nullptr;
  }
  if (!audio && queue.front()->pts_us >= 0) {
    const int64_t clock_us = playback_position(core);
    while (queue.size() > 1 && queue[1]->pts_us >= 0 &&
           queue[1]->pts_us + 100000 < clock_us) {
      auto *late = queue.front();
      queue.pop_front();
      bytes -= late->data_size;
      rillight_core_release_frame(late);
    }
    // MediaCodec can queue a monotonic presentation deadline. Give the
    // compositor a few vsyncs of lead time instead of racing the next vsync
    // with an immediate release on every 60 fps frame.
    const bool scheduled_surface = queue.front()->type == RILLIGHT_CORE_VIDEO_MEDIACODEC;
    const int64_t lead_us = scheduled_surface ? 50000 : 10000;
    if (queue.front()->pts_us > clock_us + lead_us &&
        !(core->state == RILLIGHT_CORE_PAUSED &&
          !core->paused_video_frame_emitted)) return nullptr;
  }
  if (type == RILLIGHT_CORE_VIDEO_RGBA &&
      queue.front()->type != RILLIGHT_CORE_VIDEO_RGBA &&
      queue.front()->type != RILLIGHT_CORE_VIDEO_MACOS_BUFFER &&
      queue.front()->type != RILLIGHT_CORE_VIDEO_MACOS_LINEAR &&
      queue.front()->type != RILLIGHT_CORE_VIDEO_RGBA16F) return nullptr;
  auto *frame = queue.front();
  queue.pop_front();
  bytes -= frame->data_size;
  if (frame->type == RILLIGHT_CORE_AUDIO_S16 && core->volume != 1.0) {
    auto *samples = reinterpret_cast<int16_t *>(frame->data);
    const int count = frame->data_size / sizeof(int16_t);
    for (int index = 0; index < count; ++index) {
      const double value = std::round(samples[index] * core->volume);
      samples[index] = static_cast<int16_t>(std::clamp(value, -32768.0, 32767.0));
    }
  }
  if (!audio) {
    if (frame->type == RILLIGHT_CORE_VIDEO_MEDIACODEC) {
      const auto now = Clock::now();
      const auto remaining_us = core->state == RILLIGHT_CORE_PLAYING && frame->pts_us >= 0
          ? std::max<int64_t>(0, frame->pts_us - playback_position(core, now)) : 0;
      static_cast<VideoOutputFrame*>(frame)->presentation_time_ns =
          std::chrono::duration_cast<std::chrono::nanoseconds>(now.time_since_epoch()).count() +
          static_cast<int64_t>(remaining_us * 1000 / core->speed);
    }
    core->paused_video_frame_emitted = true;
    rillight_core_release_frame(core->displayed_clean);
    core->displayed_clean = nullptr;
    if (core->subtitle_index >= 0 || core->secondary_subtitle_index >= 0) {
      core->displayed_clean = frame;
      frame = compose_displayed_frame(core, false);
      if (!frame) {
        // Rendering failure cannot interrupt video or expose partial pixels.
        frame = core->displayed_clean;
        core->displayed_clean = nullptr;
      }
    }
  }
  core->wake.notify_all();
  return frame;
}

void rillight_core_release_frame(RillightCoreFrame *frame) {
  if (!frame) return;
  if (!rillight_core_frame_is_audio(frame->type)) {
    auto *video = static_cast<VideoOutputFrame *>(frame);
    if (video->data) video->buffers->Recycle(video->data, video->data_size);
    delete video;
    return;
  }
  delete[] frame->data;
  delete frame;
}
}  // extern "C"
