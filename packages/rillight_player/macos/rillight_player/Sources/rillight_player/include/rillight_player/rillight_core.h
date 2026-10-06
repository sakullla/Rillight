#ifndef RILLIGHT_CORE_H_
#define RILLIGHT_CORE_H_

#include <stdint.h>

#if defined(_WIN32)
#define RILLIGHT_CORE_API __declspec(dllexport)
#else
#define RILLIGHT_CORE_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define RILLIGHT_CORE_ABI_VERSION 10

/* Non-FFmpeg failure: the Dolby Vision base layer cannot be displayed with
 * the currently implemented color pipeline. Reported in ffmpeg_error. */
#define RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI (-20001)

typedef struct RillightCore RillightCore;
typedef struct RillightCoreFrame RillightCoreFrame;
/* Cropped premultiplied sRGB subtitle plane, borrowed from its video frame.
 * x/y locate it within the converted video image, before SAR/rotation/fit. */
typedef struct RillightCoreSubtitleOverlay {
  uint32_t struct_size;
  int x, y, width, height, stride;
  const uint8_t *data;
} RillightCoreSubtitleOverlay;

typedef enum RillightCoreState {
  RILLIGHT_CORE_IDLE = 0,
  RILLIGHT_CORE_OPENING = 1,
  RILLIGHT_CORE_READY = 2,
  RILLIGHT_CORE_PLAYING = 3,
  RILLIGHT_CORE_PAUSED = 4,
  RILLIGHT_CORE_BUFFERING = 5,
  RILLIGHT_CORE_RECOVERING = 6,
  RILLIGHT_CORE_ENDED = 7,
  RILLIGHT_CORE_FAILED = 8,
  RILLIGHT_CORE_CLOSING = 9
} RillightCoreState;

typedef enum RillightCoreFrameType {
  RILLIGHT_CORE_VIDEO_RGBA = 1,
  RILLIGHT_CORE_AUDIO_S16 = 2,
  RILLIGHT_CORE_VIDEO_D3D11 = 3,
  RILLIGHT_CORE_VIDEO_MEDIACODEC = 4,
  RILLIGHT_CORE_VIDEO_ANDROID_P010 = 5,
  /* Tightly packed little-endian RGBA16F. 1.0 is SDR white; values above 1.0
   * are highlights. take_frame(VIDEO_RGBA) also returns this type when the
   * macOS EDR sink is enabled. Callers must branch on frame->type. */
  RILLIGHT_CORE_VIDEO_RGBA16F = 6,
  /* One compressed E-AC-3 JOC or TrueHD access unit. Produced only when the
   * configured sink accepts that format and playback speed is 1. */
  RILLIGHT_CORE_AUDIO_PASSTHROUGH = 7
} RillightCoreFrameType;

typedef enum RillightCoreChannelLayout {
  RILLIGHT_CORE_CH_LAYOUT_NONE = 0,
  RILLIGHT_CORE_CH_LAYOUT_MONO = 1,
  RILLIGHT_CORE_CH_LAYOUT_STEREO = 2,
  RILLIGHT_CORE_CH_LAYOUT_5POINT1 = 6,
  RILLIGHT_CORE_CH_LAYOUT_7POINT1 = 8
} RillightCoreChannelLayout;

typedef enum RillightCoreAudioDelivery {
  RILLIGHT_CORE_AUDIO_DELIVERY_NONE = 0,
  RILLIGHT_CORE_AUDIO_DELIVERY_PCM_STEREO = 1,
  RILLIGHT_CORE_AUDIO_DELIVERY_PCM_DOWNMIX = 2,
  RILLIGHT_CORE_AUDIO_DELIVERY_PCM_MULTICHANNEL = 3,
  RILLIGHT_CORE_AUDIO_DELIVERY_PASSTHROUGH = 4
} RillightCoreAudioDelivery;

typedef enum RillightCorePassthroughKind {
  RILLIGHT_CORE_PASSTHROUGH_NONE = 0,
  RILLIGHT_CORE_PASSTHROUGH_EAC3_JOC = 1,
  RILLIGHT_CORE_PASSTHROUGH_TRUEHD = 2
} RillightCorePassthroughKind;

typedef enum RillightCoreVideoOutputKind {
  RILLIGHT_CORE_VIDEO_OUT_UNKNOWN = 0,
  RILLIGHT_CORE_VIDEO_OUT_SDR = 1,
  RILLIGHT_CORE_VIDEO_OUT_HDR = 2,
  /* Android only, and only after MediaCodec has selected video/dolby-vision.
   * Windows scRGB, macOS EDR and SDR tone maps never use this value. */
  RILLIGHT_CORE_VIDEO_OUT_DOLBY_VISION = 3
} RillightCoreVideoOutputKind;

typedef enum RillightCoreDoviReconstruction {
  RILLIGHT_CORE_DOVI_RECON_NONE = 0,
  RILLIGHT_CORE_DOVI_RECON_RPU = 1,
  RILLIGHT_CORE_DOVI_RECON_FEL = 2,
  /* Residual was required and was not composed. The picture is the compatible
   * base layer, not a completed FEL reconstruction. */
  RILLIGHT_CORE_DOVI_RECON_BASE_FALLBACK = 3
} RillightCoreDoviReconstruction;

#define RILLIGHT_CORE_DOVI_PROFILE_UNKNOWN (-1)
#define RILLIGHT_CORE_DOVI_PROFILE_NONE 0
#define RILLIGHT_CORE_AUDIO_ACCEPT_EAC3 1u
#define RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD 2u

typedef enum RillightCoreTrackType {
  RILLIGHT_CORE_TRACK_VIDEO = 1,
  RILLIGHT_CORE_TRACK_AUDIO = 2,
  RILLIGHT_CORE_TRACK_SUBTITLE = 3
} RillightCoreTrackType;

/* Capability bits describe FFmpeg decoder configurations, not a working GPU.
 * actual_hardware is NONE until this session successfully opens a device. */
typedef enum RillightCoreHardware {
  RILLIGHT_CORE_HW_NONE = 0,
  RILLIGHT_CORE_HW_D3D11 = 1,
  RILLIGHT_CORE_HW_VIDEOTOOLBOX = 2,
  RILLIGHT_CORE_HW_VAAPI = 4,
  RILLIGHT_CORE_HW_MEDIACODEC = 8
} RillightCoreHardware;

typedef struct RillightCoreTrack {
  uint32_t struct_size;
  int stream_index;
  RillightCoreTrackType type;
  int codec_id;
  char codec_name[32];
  char language[32];
  char title[128];
  int is_default;
  int width;
  int height;
  int sample_rate;
  int channels;
  uint32_t decoder_hardware_capabilities;
  uint32_t actual_hardware;
  int is_external;
} RillightCoreTrack;

/* The owner must keep callbacks alive until rillight_core_destroy returns.
 * read/seek may block only while the transport session remains cancellable.
 * read returns 0 for real EOF and a negative FFmpeg error for temporary or
 * fatal failures; temporary no-data must be AVERROR(EAGAIN), not EOF.
 * open returns an opaque handle or NULL. Nested FFmpeg opens use this same
 * callback; authorization and the protocol allow-list belong to its owner.
 * The external-subtitle loader may call open/read/close on a separate handle
 * concurrently with media IO. cancel must unblock both kinds of handles.
 * cancel_media_io must promptly interrupt the current media read OR seek,
 * including a seek callback blocked in transport IO. It is invoked while the
 * core state mutex is held so new-timeline IO cannot start before the signal
 * returns. It must only signal, not call core APIs or wait for worker progress.
 * The cancellation must not poison the next operation: the same media handle
 * must remain seekable and readable after the new seek resets transport state.
 * Subtitle handles must not be cancelled by this targeted signal. */
typedef struct RillightCoreIo {
  void *opaque;
  void *(*open)(void *opaque, const char *url, int flags);
  int (*read)(void *opaque, void *handle, uint8_t *data, int size);
  int64_t (*seek)(void *opaque, void *handle, int64_t offset, int whence);
  void (*close)(void *opaque, void *handle);
  void (*cancel)(void *opaque);
  void (*cancel_media_io)(void *opaque);
} RillightCoreIo;

struct RillightCoreFrame {
  uint32_t struct_size;
  RillightCoreFrameType type;
  uint64_t session_id;
  uint64_t timeline_version;
  int64_t pts_us;
  int width;
  int height;
  int stride;
  int sample_rate;
  int channels;
  int sample_count;
  int data_size;
  uint8_t *data;
  /* VIDEO_RGBA source display metadata. RGBA bytes are full-range after the
   * core's YUV range/matrix conversion. The sink still applies SAR and the
   * FFmpeg display matrix when presenting the frame. No matrix means identity. */
  int sar_num;
  int sar_den;
  int source_color_range;
  int source_color_space;
  int source_color_primaries;
  int source_color_transfer;
  int has_display_matrix;
  int32_t display_matrix[9];
  /* Audio only. channel_layout is RillightCoreChannelLayout. audio_codec_id is
   * RillightCorePassthroughKind for PASSTHROUGH and 0 for PCM. audio_atmos is
   * 1 only for passthrough when the sink reports Atmos. */
  int channel_layout;
  int audio_codec_id;
  int audio_delivery;
  int audio_atmos;
};

/* Pull-output contract for platform sinks:
 * - VIDEO_RGBA owns tightly packed RGBA rows of `stride` bytes and is timed
 *   against snapshot.position_us. AUDIO_S16 owns interleaved signed 16-bit
 *   PCM at 48 kHz. channels is the negotiated count: a 6-channel source stays
 *   6 when the sink allows it, and is downmixed to stereo when it does not.
 *   AUDIO_PASSTHROUGH owns one compressed access unit. take_frame of either
 *   audio type dequeues the next audio frame; branch on frame->type.
 *   The caller must not mutate frame data.
 * - take_frame transfers one reference to the caller; release_frame is valid
 *   after core destruction. A sink must release every taken frame exactly once.
 * - Seek, track selection and reopen advance timeline_version. A sink discards
 *   and releases frames whose session_id or timeline_version is no longer
 *   current, including frames already handed to a platform queue.
 * - The audio sink reports the media PTS at the end of submitted PCM and the
 *   remaining device delay in media microseconds through report_audio_played.
 *   Convert wall-clock device latency using playback_speed before reporting.
 *   When submitted audio has drained and no more PCM is available, the sink
 *   calls report_audio_unavailable once to hand the clock to monotonic time.
 *   Later audio reports behind that clock are rejected. After source_eof, the
 *   sink reports
 *   output_drained only when platform audio/video queues are empty. */

typedef struct RillightCoreSnapshot {
  uint32_t struct_size;
  uint32_t abi_version;
  uint64_t session_id;
  uint64_t operation_id;
  uint64_t timeline_version;
  RillightCoreState state;
  int ffmpeg_error;
  int video_stream_index;
  int audio_stream_index;
  int subtitle_stream_index;
  int64_t duration_us;
  int64_t position_us;
  int first_video_frame_ready;
  int first_audio_frame_ready;
  int source_eof;
  int queued_video_frames;
  int queued_audio_frames;
  double playback_speed;
  uint32_t preferred_hardware;
  int allow_software_fallback;
  int external_subtitle_pending;
  /* dolby_vision_profile is -1 until open, then 0 or the container profile.
   * dolby_vision_compatibility is -1 until open, then the base-layer id.
   * video_output_kind stays unknown until the presentation path fills it.
   * It is native Dolby only for an Android video/dolby-vision decoder.
   * dovi_reconstruction is FEL only after the enhancement layer is composed.
   * Enhancement pairs stay 0 until requested. Effective values may be lower
   * than the request; the saved request is not rewritten. */
  int dolby_vision_profile;
  int video_output_kind;
  int audio_delivery;
  int audio_channels;
  int audio_layout;
  int audio_atmos;
  int audio_codec_id;
  int requested_interpolation;
  int effective_interpolation;
  int requested_anime4k;
  int effective_anime4k;
  int requested_super_resolution;
  int effective_super_resolution;
  int requested_denoise;
  int effective_denoise;
  int requested_sharpen;
  int effective_sharpen;
  int dovi_reconstruction;
  int dolby_vision_compatibility;
} RillightCoreSnapshot;

static inline int rillight_core_frame_is_audio(int type) {
  return type == RILLIGHT_CORE_AUDIO_S16 ||
         type == RILLIGHT_CORE_AUDIO_PASSTHROUGH;
}

/* Stereo S16 when channels was not set, so existing offset math stays valid. */
static inline int rillight_core_pcm_bytes_per_frame(
    const RillightCoreFrame *frame) {
  const int channels = frame && frame->channels > 0 ? frame->channels : 2;
  return channels * 2;
}

/* Version 1 display geometry uses a single unit (physical or logical pixels).
 * Zero enabled restores authored sizing. Session identity rejects late callers.
 * Text is rerasterized; bitmap subtitles and video pixels are never scaled. */
typedef struct RillightCoreSubtitlePresentation {
  uint32_t struct_size;
  uint32_t version;
  int32_t enabled;
  int32_t original_ass;
  double display_width;
  double display_height;
  double font_size;
  double user_scale;
  double safe_horizontal;
  double safe_vertical;
} RillightCoreSubtitlePresentation;
RILLIGHT_CORE_API int rillight_core_set_subtitle_presentation(
    RillightCore *core, const RillightCoreSubtitlePresentation *presentation,
    uint64_t session_id);

RILLIGHT_CORE_API uint32_t rillight_core_abi_version(void);
RILLIGHT_CORE_API const char *rillight_core_ffmpeg_versions(void);
RILLIGHT_CORE_API RillightCore *rillight_core_create(const RillightCoreIo *io);
RILLIGHT_CORE_API void rillight_core_destroy(RillightCore *core);
/* Desktop-only transport adapter. Accepts sealed HTTP URLs on 127.0.0.1;
 * neither credentials nor remote addresses may cross this boundary. The
 * paired destroy owns the IO adapter and waits for all native reads to stop. */
RILLIGHT_CORE_API RillightCore *rillight_core_create_loopback(void);
RILLIGHT_CORE_API void rillight_core_destroy_loopback(RillightCore *core);
/* Configure only while idle, ended, or failed. The selected decoder is reported
 * per track after opening; actual_hardware changes only after a hardware frame
 * is decoded. If fallback is false, missing device/configuration fails open. */
RILLIGHT_CORE_API int rillight_core_configure_hardware(
    RillightCore *core, RillightCoreHardware preference,
    int allow_software_fallback);
/* Device PCM capacity and compressed formats the sink can actually open.
 * max_pcm_channels is 1..8. accepted_passthrough is EAC3 and/or TRUEHD.
 * reports_atmos must be 0 or 1 and is copied to the snapshot only while a
 * compressed passthrough frame is produced. Allowed outside CLOSING. A changed
 * channel count or accept mask drops queued audio; the sink flushes its device
 * buffer and the next decoded frame follows the new route. macOS callers pass
 * accepted_passthrough 0. */
typedef struct RillightCoreAudioSink {
  uint32_t struct_size;
  int max_pcm_channels;
  uint32_t accepted_passthrough;
  int reports_atmos;
} RillightCoreAudioSink;
RILLIGHT_CORE_API int rillight_core_configure_audio_sink(
    RillightCore *core, const RillightCoreAudioSink *sink);
/* Idle only. When enabled, PCM remains at source rate and the sink must apply
 * playback_speed with pitch preservation. Audio delay reports remain in media
 * time (PCM samples / sample_rate). Rate changes keep the timeline and queued
 * PCM. Leaving speed 1 drops queued passthrough so the sink can open PCM;
 * passthrough resumes only after speed returns to 1 and the sink still accepts
 * that format. Disabled by default: other sinks retain atempo and seek. */
RILLIGHT_CORE_API int rillight_core_configure_external_audio_speed(
    RillightCore *core, int enabled);
/* Bound RGBA conversion to the physical output viewport without changing the
 * decoded source, timestamps, or timeline. Zero dimensions keep source size.
 * The next converted frame adopts the new size; sinks still fit/rotate it. */
RILLIGHT_CORE_API int rillight_core_set_video_output_size(
    RillightCore *core, int width, int height);
/* Android owned-core output. The core retains an ANativeWindow reference.
 * Direct decoder Surface replacement advances the timeline and recreates
 * MediaCodec at the current position. P010/EGL replacement preserves decoding.
 * NULL detaches output; callers must never present an old
 * timeline to a replacement Surface. Other platforms reject this API.
 * MEDIACODEC frames retain decoder output buffers, with no CPU pixel copy. */
RILLIGHT_CORE_API int rillight_core_set_android_window(RillightCore *core,
                                                      void *native_window,
                                                      uint32_t dovi_profiles);
RILLIGHT_CORE_API int rillight_core_render_mediacodec_frame(
    const RillightCoreFrame *frame);
/* Owned GLES presentation on the caller's output thread. Release on the same
 * thread before returning the Surface. HDR requires display/EGL support. */
/* core may be NULL. On success the core records HDR or SDR from the EGL
 * surface that was actually created, never native Dolby Vision. */
RILLIGHT_CORE_API int rillight_core_render_android_color_frame(
    const RillightCoreFrame *frame, void *native_window, int hdr_display_supported,
    RillightCore *core);
RILLIGHT_CORE_API void rillight_core_release_android_color_renderer(void);
RILLIGHT_CORE_API double rillight_core_video_frame_rate(RillightCore *core);
/* Output cadence after interpolation. This is the source rate, or exactly
 * twice that rate while double interpolation is effective. It does not change
 * media duration or audio speed. */
RILLIGHT_CORE_API double rillight_core_output_frame_rate(RillightCore *core);

#define RILLIGHT_CORE_ENHANCE_REASON_OFF 0
#define RILLIGHT_CORE_ENHANCE_REASON_ACTIVE 1
#define RILLIGHT_CORE_ENHANCE_REASON_NATIVE_DOLBY 2
#define RILLIGHT_CORE_ENHANCE_REASON_MODEL_UNAVAILABLE 3
#define RILLIGHT_CORE_ENHANCE_REASON_OVERLOAD 4
#define RILLIGHT_CORE_ENHANCE_REASON_REFRESH_CAP 5
#define RILLIGHT_CORE_ENHANCE_REASON_NO_PICTURE 6
#define RILLIGHT_CORE_ENHANCE_REASON_CAPACITY 7

#define RILLIGHT_CORE_INTERP_BACKEND_NONE 0
#define RILLIGHT_CORE_INTERP_BACKEND_SCENE_BLEND 1
#define RILLIGHT_CORE_INTERP_BACKEND_RIFE 2
#define RILLIGHT_CORE_INTERP_BACKEND_VIDEOTOOLBOX 3
#define RILLIGHT_CORE_ANIME4K_BACKEND_NONE 0
#define RILLIGHT_CORE_ANIME4K_BACKEND_GRADIENT 1
#define RILLIGHT_CORE_SR_BACKEND_NONE 0
#define RILLIGHT_CORE_SR_BACKEND_REALESRGAN 1
#define RILLIGHT_CORE_SR_BACKEND_VIDEOTOOLBOX 2

/* interpolation is 0 or 2. anime4k is 0, 1 (light) or 2 (strong).
 * super_resolution is 0 or 2. denoise and sharpen are 0..100.
 * Anime4K and super-resolution cannot both be non-zero.
 * accept_leave_native_dolby must be 1 before enhancement can leave a
 * video/dolby-vision decoder. display_refresh_hz 0 means unknown. */
typedef struct RillightCoreEnhancementRequest {
  uint32_t struct_size;
  int interpolation;
  int anime4k;
  int super_resolution;
  int denoise;
  int sharpen;
  int accept_leave_native_dolby;
  int display_refresh_hz;
} RillightCoreEnhancementRequest;

typedef struct RillightCoreEnhancementFacts {
  uint32_t struct_size;
  int native_dolby;
  double source_frame_rate;
  int picture_available;
} RillightCoreEnhancementFacts;

typedef struct RillightCoreEnhancementLoad {
  uint32_t struct_size;
  int drop_interpolation;
  int drop_scale;
  int drop_spatial;
} RillightCoreEnhancementLoad;

typedef struct RillightCoreEnhancementStatus {
  uint32_t struct_size;
  int requested_interpolation;
  int effective_interpolation;
  int requested_anime4k;
  int effective_anime4k;
  int requested_super_resolution;
  int effective_super_resolution;
  int requested_denoise;
  int effective_denoise;
  int requested_sharpen;
  int effective_sharpen;
  int reason_interpolation;
  int reason_anime4k;
  int reason_super_resolution;
  int reason_denoise;
  int reason_sharpen;
  int interpolation_backend;
  int anime4k_backend;
  int super_resolution_backend;
  int left_native_dolby;
  double source_frame_rate;
  double output_frame_rate;
} RillightCoreEnhancementStatus;

/* Allowed outside CLOSING. Identical requests keep an overload downgrade.
 * A changed request restores the selected stages and still does not write the
 * media URL, duration, or audio speed. */
RILLIGHT_CORE_API int rillight_core_configure_enhancement(
    RillightCore *core, const RillightCoreEnhancementRequest *request);
/* met is 0 or 1. monotonic_us is a caller clock. One continuous second of
 * misses drops interpolation, then upscaling, then denoise and sharpen.
 * Requested values stay put. */
RILLIGHT_CORE_API int rillight_core_note_frame_deadline(
    RillightCore *core, int met, int64_t monotonic_us);
RILLIGHT_CORE_API int rillight_core_enhancement_status(
    RillightCore *core, RillightCoreEnhancementStatus *status);
RILLIGHT_CORE_API int rillight_enhancement_resolve(
    const RillightCoreEnhancementRequest *request,
    const RillightCoreEnhancementFacts *facts,
    const RillightCoreEnhancementLoad *load,
    RillightCoreEnhancementStatus *status);
/* RGBA8 only. previous may be null. Subtitle bytes are not accepted.
 * dst and midpoint are tightly packed. midpoint_bytes is 0 on a hard cut. */
RILLIGHT_CORE_API int rillight_enhancement_process_rgba(
    const RillightCoreEnhancementRequest *request,
    const RillightCoreEnhancementFacts *facts,
    const RillightCoreEnhancementLoad *load, const uint8_t *src, int width,
    int height, int stride, const uint8_t *previous, int previous_stride,
    uint8_t *dst, int dst_capacity, int *out_width, int *out_height,
    uint8_t *midpoint, int midpoint_capacity, int *midpoint_bytes);
/* Optional Windows GPU sink, enabled while idle; disabling it is allowed
 * during playback to recover from unavailable cross-adapter sharing.
 * VIDEO_D3D11 requests
 * consume the video queue and may also return CPU RGBA fallback frames.
 * GPU frames have NULL data, with data_size accounting for GPU allocation.
 * frame_d3d11_texture returns a borrowed immutable ID3D11Texture2D valid until
 * release_frame. All frames retain session/timeline/display metadata.
 * Existing CPU sinks keep the default RGBA output contract. */
RILLIGHT_CORE_API int rillight_core_configure_gpu_video(RillightCore *core,
                                                       int enabled);
RILLIGHT_CORE_API void *rillight_core_frame_d3d11_texture(
    const RillightCoreFrame *frame);
/* Opt-in native Windows scRGB output, enabled while idle after GPU video.
 * HDR/DV GPU frames become immutable FP16, with 1.0 = 80 nits. CPU fallback
 * remains sRGB RGBA8888. A sink must inspect the native texture's format and
 * must not pass FP16 through Flutter's 8-bit external-texture contract. */
RILLIGHT_CORE_API int rillight_core_configure_hdr_video(RillightCore *core,
                                                       int enabled);
/* Opt-in macOS extended-range output, configured while idle, ended, or failed.
 * PQ, HLG and supported Dolby Vision frames are then emitted as RGBA16F instead
 * of 8-bit sRGB. SDR frames stay VIDEO_RGBA. Disabling is allowed in those same
 * states. This is not the Windows scRGB contract and does not certify Dolby. */
RILLIGHT_CORE_API int rillight_core_configure_macos_edr(RillightCore *core,
                                                       int enabled);
RILLIGHT_CORE_API int rillight_core_frame_subtitle_overlay(
    const RillightCoreFrame *frame, RillightCoreSubtitleOverlay *overlay);
/* Open accepts an operation and starts a worker. First-frame completion is
 * reported by snapshot state/flags; acceptance alone is not playback success.
 * Calls with a stale operation_id fail. Each accepted open creates a session. */
RILLIGHT_CORE_API int rillight_core_open(RillightCore *core, const char *url,
                                        uint64_t operation_id);
/* Open at a resume position before decoding/publishing the initial timeline.
 * This avoids displaying a frame from the beginning before a later seek.
 * position_us must be nonnegative; zero preserves ordinary open behavior. */
RILLIGHT_CORE_API int rillight_core_open_at(RillightCore *core, const char *url,
                                           int64_t position_us,
                                           uint64_t operation_id);
RILLIGHT_CORE_API int rillight_core_set_playing(RillightCore *core, int playing,
                                               uint64_t operation_id);
RILLIGHT_CORE_API int rillight_core_seek(RillightCore *core, int64_t position_us,
                                        uint64_t operation_id);
RILLIGHT_CORE_API int rillight_core_select_audio(RillightCore *core,
                                                 int stream_index,
                                                 uint64_t operation_id);
/* -1 disables subtitle composition. A failed selection preserves the old
 * subtitle stream; snapshot.subtitle_stream_index changes only on success. */
RILLIGHT_CORE_API int rillight_core_select_subtitle(RillightCore *core,
                                                    int stream_index,
                                                    uint64_t operation_id);
/* Add an external ASS/SSA, SRT, or WebVTT subtitle using the same controlled
 * IO callbacks as media. SRT/WebVTT are parsed with FFmpeg and composed with
 * libass. Acceptance is asynchronous and does not change the selected track or
 * timeline. Wait for snapshot.external_subtitle_pending to clear, then inspect
 * ffmpeg_error and the track list. A successful track has is_external=1 and a
 * synthetic stream_index; select it with select_subtitle. Invalid, oversized,
 * or failed reads leave the current subtitle and track list unchanged. */
RILLIGHT_CORE_API int rillight_core_add_external_subtitle(
    RillightCore *core, const char *url, uint64_t operation_id);
RILLIGHT_CORE_API int rillight_core_set_speed(RillightCore *core, double speed,
                                             uint64_t operation_id);
/* Gain is applied to owned S16 PCM as it leaves the core; 1.0 is unchanged,
 * 0.0 is muted and values above 1.0 saturate safely. */
RILLIGHT_CORE_API int rillight_core_set_volume(RillightCore *core, double gain,
                                              uint64_t operation_id);
RILLIGHT_CORE_API int rillight_core_track_count(RillightCore *core);
RILLIGHT_CORE_API int rillight_core_get_track(RillightCore *core, int ordinal,
                                             RillightCoreTrack *track);
RILLIGHT_CORE_API int rillight_core_report_audio_played(
    RillightCore *core, uint64_t session_id, uint64_t timeline_version,
    int64_t queued_end_pts_us, int64_t remaining_media_delay_us);
/* Called after the sink's PCM and device queue have drained. Repeated calls
 * for the same timeline are harmless and do not restart the monotonic clock. */
RILLIGHT_CORE_API int rillight_core_report_audio_unavailable(
    RillightCore *core, uint64_t session_id, uint64_t timeline_version);
RILLIGHT_CORE_API int rillight_core_report_output_drained(
    RillightCore *core, uint64_t session_id, uint64_t timeline_version);
RILLIGHT_CORE_API int rillight_core_snapshot(RillightCore *core,
                                             RillightCoreSnapshot *snapshot);
/* Selected ISO BMFF track_ID values from AVStream.id. Returns -1 per missing
 * video/audio track or any format outside the MP4/MOV demuxer family. These
 * are container identities, not FFmpeg stream-list indices. */
RILLIGHT_CORE_API int rillight_core_container_track_ids(
    RillightCore *core, int *video_track_id, int *audio_track_id);
/* Ownership transfers to the caller. Discard frames with an old session or
 * timeline_version before publishing them to a platform surface. */
RILLIGHT_CORE_API RillightCoreFrame *rillight_core_take_frame(RillightCore *core,
                                                              int type);
RILLIGHT_CORE_API void rillight_core_release_frame(RillightCoreFrame *frame);

#ifdef __cplusplus
}
#endif
#endif
