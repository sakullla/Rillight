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

#define RILLIGHT_CORE_ABI_VERSION 6

typedef struct RillightCore RillightCore;
typedef struct RillightCoreFrame RillightCoreFrame;

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
  RILLIGHT_CORE_AUDIO_S16 = 2
} RillightCoreFrameType;

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
};

/* Pull-output contract for platform sinks:
 * - VIDEO_RGBA owns tightly packed RGBA rows of `stride` bytes and is timed
 *   against snapshot.position_us. AUDIO_S16 owns interleaved signed 16-bit
 *   stereo PCM at 48 kHz. The caller must not mutate frame data.
 * - take_frame transfers one reference to the caller; release_frame is valid
 *   after core destruction. A sink must release every taken frame exactly once.
 * - Seek, track selection and reopen advance timeline_version. A sink discards
 *   and releases frames whose session_id or timeline_version is no longer
 *   current, including frames already handed to a platform queue.
 * - The audio sink reports the media PTS actually heard and remaining device
 *   delay through report_audio_played. With no audio, snapshot.position_us is
 *   driven by the core monotonic clock. After source_eof, the sink reports
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
} RillightCoreSnapshot;

RILLIGHT_CORE_API uint32_t rillight_core_abi_version(void);
RILLIGHT_CORE_API const char *rillight_core_ffmpeg_versions(void);
RILLIGHT_CORE_API RillightCore *rillight_core_create(const RillightCoreIo *io);
RILLIGHT_CORE_API void rillight_core_destroy(RillightCore *core);
/* Configure only while idle, ended, or failed. The selected decoder is reported
 * per track after opening; actual_hardware changes only after a hardware frame
 * is decoded. If fallback is false, missing device/configuration fails open. */
RILLIGHT_CORE_API int rillight_core_configure_hardware(
    RillightCore *core, RillightCoreHardware preference,
    int allow_software_fallback);
/* Open accepts an operation and starts a worker. First-frame completion is
 * reported by snapshot state/flags; acceptance alone is not playback success.
 * Calls with a stale operation_id fail. Each accepted open creates a session. */
RILLIGHT_CORE_API int rillight_core_open(RillightCore *core, const char *url,
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
RILLIGHT_CORE_API int rillight_core_track_count(RillightCore *core);
RILLIGHT_CORE_API int rillight_core_get_track(RillightCore *core, int ordinal,
                                             RillightCoreTrack *track);
RILLIGHT_CORE_API int rillight_core_report_audio_played(
    RillightCore *core, uint64_t session_id, uint64_t timeline_version,
    int64_t played_pts_us, int64_t device_delay_us);
RILLIGHT_CORE_API int rillight_core_report_output_drained(
    RillightCore *core, uint64_t session_id, uint64_t timeline_version);
RILLIGHT_CORE_API int rillight_core_snapshot(RillightCore *core,
                                             RillightCoreSnapshot *snapshot);
/* Ownership transfers to the caller. Discard frames with an old session or
 * timeline_version before publishing them to a platform surface. */
RILLIGHT_CORE_API RillightCoreFrame *rillight_core_take_frame(RillightCore *core,
                                                              int type);
RILLIGHT_CORE_API void rillight_core_release_frame(RillightCoreFrame *frame);

#ifdef __cplusplus
}
#endif
#endif
