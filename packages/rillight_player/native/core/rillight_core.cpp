#include "rillight_core.h"
#include "bitmap_subtitle.h"
#include "dts_packet_recovery.h"
#include "video_buffer_pool.h"
#include "video_frame_cost.h"
#include "dovi_profile.h"
#include "h264_access_unit.h"
#include "portable_color_pipeline.h"
#if defined(__ANDROID__)
#include "android_color_pipeline.h"
#endif
#if defined(_WIN32)
#include "windows_color_pipeline.h"
#include <d3d11.h>
#endif

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cctype>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>
#if defined(__ANDROID__)
#include <unistd.h>
#include <android/native_window.h>
#endif

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/aes.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libavutil/opt.h>
#if defined(__ANDROID__)
#include <libavcodec/mediacodec.h>
#include <libavutil/hwcontext_mediacodec.h>
#endif
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#if RILLIGHT_HAVE_LIBASS
#include <ass/ass.h>
#endif
}

int rillight_dovi_base_rejected(int profile, int compatibility);
void tonemap_rgba(uint8_t *data, int stride, int width, int height,
                  int transfer);

namespace {
constexpr int kIoBufferSize = 32768;
constexpr size_t kMaxVideoFrames = 3;
constexpr size_t kMaxAudioFrames = 16;
constexpr size_t kMaxVideoBytes = 128u * 1024u * 1024u;
constexpr size_t kMaxAudioBytes = 4u * 1024u * 1024u;
#if RILLIGHT_HAVE_LIBASS
constexpr size_t kMaxExternalSubtitleBytes = 4u * 1024u * 1024u;
constexpr size_t kMaxExternalSubtitleTotalBytes = 16u * 1024u * 1024u;
constexpr size_t kMaxExternalSubtitleTracks = 16;
constexpr int kExternalSubtitleStreamBase = 1000000;
#endif
using Clock = std::chrono::steady_clock;

struct LoopbackIo {
  std::atomic<uint64_t> media_generation{0};
  std::atomic<int> media_open_error{0};
  std::atomic<bool> closing{false};
  std::mutex thread_mutex;
  std::thread::id media_thread;
};

struct LoopbackHandle {
  LoopbackIo *owner;
  AVIOContext *io = nullptr;
  std::string url;
  int64_t position = 0;
  bool media = false;
  std::atomic<uint64_t> read_generation{0};
  uint64_t open_generation = 0;
};

bool sealed_loopback_url(const char *url) {
  if (!url) return false;
  constexpr std::string_view prefix = "http://127.0.0.1:";
  const std::string_view value(url);
  if (value.size() < prefix.size() || value.substr(0, prefix.size()) != prefix)
    return false;
  size_t offset = prefix.size();
  const size_t port_start = offset;
  while (offset < value.size() && value[offset] >= '0' &&
         value[offset] <= '9') ++offset;
  return offset > port_start && offset - port_start <= 5 &&
         offset < value.size() && value[offset] == '/' &&
         value.find('@') == std::string_view::npos &&
         value.find('\\') == std::string_view::npos;
}

int loopback_interrupted(void *opaque) {
  const auto *handle = static_cast<LoopbackHandle *>(opaque);
  return handle->owner->closing.load() ||
         (handle->media && handle->read_generation.load() !=
                               handle->owner->media_generation.load());
}

int loopback_open_at(LoopbackHandle *handle, int64_t position) {
  if (handle->owner->closing.load() || !sealed_loopback_url(handle->url.c_str()))
    return AVERROR_EXIT;
  const uint64_t generation = handle->owner->media_generation.load();
  AVDictionary *options = nullptr;
  // The local proxy allows 20 s for upstream headers and owns network recovery.
  // A shorter loopback timeout aborts a healthy in-flight request first. The
  // 45 s application open deadline and interrupt callback still bound/cancel it.
  av_dict_set(&options, "rw_timeout", "45000000", 0);
  // Every reconnect must retain the same sealed route and redirect policy.
  av_dict_set(&options, "max_redirects", "0", 0);
  // Reopening after cancellation must request the target directly. Opening at
  // byte zero first creates an obsolete header request beside the media read.
  if (position > 0) av_dict_set_int(&options, "offset", position, 0);
  const AVIOInterruptCB interrupt{loopback_interrupted, handle};
  AVIOContext *replacement = nullptr;
  int result = avio_open2(&replacement, handle->url.c_str(), AVIO_FLAG_READ,
                          &interrupt, &options);
  av_dict_free(&options);
  if (result < 0) return result;
  // HTTP's offset option already positions the protocol at this byte. The
  // newly allocated AVIO buffer still starts at logical zero; a small avio_seek
  // would consume the offset again rather than repositioning the protocol.
  replacement->pos = position;
  if (handle->media && handle->owner->media_generation.load() != generation) {
    avio_closep(&replacement);
    return AVERROR_EXIT;
  }
  if (handle->io) avio_closep(&handle->io);
  handle->io = replacement;
  handle->position = position;
  handle->open_generation = generation;
  return 0;
}

void *loopback_open(void *opaque, const char *url, int flags) {
  auto *owner = static_cast<LoopbackIo *>(opaque);
  if (!owner || owner->closing.load() || !sealed_loopback_url(url) ||
      !(flags & AVIO_FLAG_READ) || (flags & AVIO_FLAG_WRITE)) return nullptr;
  auto handle = std::make_unique<LoopbackHandle>();
  handle->owner = owner;
  handle->url = url;
  {
    std::lock_guard lock(owner->thread_mutex);
    if (owner->media_thread == std::thread::id())
      owner->media_thread = std::this_thread::get_id();
    handle->media = owner->media_thread == std::this_thread::get_id();
  }
  handle->read_generation = owner->media_generation.load();
  const int result = loopback_open_at(handle.get(), 0);
  if (handle->media) owner->media_open_error = result < 0 ? result : 0;
  if (result < 0) return nullptr;
  return handle.release();
}

int loopback_read(void *, void *pointer, uint8_t *data, int size) {
  auto *handle = static_cast<LoopbackHandle *>(pointer);
  if (!handle || !handle->io || size <= 0) return AVERROR(EINVAL);
  const uint64_t generation = handle->owner->media_generation.load();
  handle->read_generation = generation;
  if (handle->media && handle->open_generation != generation) {
    const int reopened = loopback_open_at(handle, handle->position);
    if (reopened < 0) return reopened;
  }
  // This is an AVIO read callback, not a request to fill the caller's buffer.
  // Container probing can grow that buffer to 16 MiB for seek-back. Filling
  // it eagerly re-downloads megabytes on every interleaved track seek.
  int result = avio_read_partial(handle->io, data, size);
  if (result > 0) handle->position += result;
  if (result == AVERROR(EIO) && !handle->owner->closing.load() &&
      handle->owner->media_generation.load() == generation &&
      loopback_open_at(handle, handle->position) == 0) {
    result = avio_read_partial(handle->io, data, size);
    if (result > 0) handle->position += result;
  }
  return result;
}

int64_t loopback_seek(void *, void *pointer, int64_t offset, int whence) {
  auto *handle = static_cast<LoopbackHandle *>(pointer);
  if (!handle || !handle->io) return AVERROR(EINVAL);
  const uint64_t generation = handle->owner->media_generation.load();
  const bool interrupted = handle->open_generation != generation;
  if (whence & AVSEEK_SIZE) return avio_size(handle->io);
  handle->read_generation = generation;
  // An interrupted HTTP read may leave FFmpeg's nested AVIO in an error
  // state. Seek on a fresh sealed route instead of reusing that connection.
  if (interrupted && (whence & ~AVSEEK_FORCE) == SEEK_SET && offset >= 0) {
    const int reopened = loopback_open_at(handle, offset);
    return reopened < 0 ? reopened : offset;
  }
  const int64_t result = avio_seek(handle->io, offset, whence & ~AVSEEK_FORCE);
  if (result >= 0) handle->position = result;
  return result;
}

void loopback_close(void *, void *pointer) {
  auto *handle = static_cast<LoopbackHandle *>(pointer);
  if (!handle) return;
  if (handle->io) avio_closep(&handle->io);
  delete handle;
}

void loopback_cancel(void *opaque) {
  auto *owner = static_cast<LoopbackIo *>(opaque);
  owner->closing = true;
  ++owner->media_generation;
}

void loopback_cancel_media(void *opaque) {
  auto *owner = static_cast<LoopbackIo *>(opaque);
  ++owner->media_generation;
}

struct Source {
  RillightCoreIo io;
  std::atomic<int> *fatal_error = nullptr;
  std::atomic<uint64_t> *timeline_signal = nullptr;
  std::atomic<uint64_t> *active_read_timeline = nullptr;
  void *handle = nullptr;
  AVIOContext *avio = nullptr;
  AVAES *aes = nullptr;
  std::array<uint8_t, 16> initial_iv{};
  std::array<uint8_t, 16> iv{};
  std::vector<uint8_t> ciphertext;
  std::vector<uint8_t> plaintext;
  size_t ciphertext_size = 0;
  size_t plaintext_size = 0;
  size_t plaintext_offset = 0;
  int64_t position = 0;
  bool encrypted_eof = false;
};

struct HardwareFormatSelection {
  AVPixelFormat preferred = AV_PIX_FMT_NONE;
  bool allow_software_fallback = true;
};

struct Decoder {
  AVCodecContext *context = nullptr;
  int stream = -1;
  std::shared_ptr<HardwareFormatSelection> hw_format;
  uint32_t hardware = RILLIGHT_CORE_HW_NONE;
  bool android_color_buffers = false;
  int error = 0;
  DtsPacketRecovery dts_recovery;
};

struct PendingPackets {
  std::deque<AVPacket*> values;
  ~PendingPackets() { Clear(); }
  void Clear() { for (auto* packet : values) av_packet_free(&packet); values.clear(); }
};

struct VideoScale {
  PortableColorPipeline portable_color_pipeline;
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
  std::shared_ptr<VideoBufferPool> buffers;
  std::shared_ptr<void> gpu_texture;
  std::shared_ptr<AVFrame> codec_frame;
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
};

#if RILLIGHT_HAVE_LIBASS
struct ExternalTextCue {
  int64_t start_ms = 0;
  int64_t duration_ms = 0;
  std::string ass_chunk;
};

struct ExternalSubtitle {
  int stream_index = -1;
  AVCodecID codec = AV_CODEC_ID_NONE;
  std::shared_ptr<const std::vector<char>> script;
  std::shared_ptr<const std::vector<ExternalTextCue>> cues;
  size_t source_bytes = 0;
};
#endif

#if RILLIGHT_HAVE_LIBASS
struct AssRenderer {
  ASS_Library *library = nullptr;
  ASS_Renderer *renderer = nullptr;
  ASS_Track *track = nullptr;
  int stream = -1;
  bool external = false;
  bool plain_text = false;
  RillightCoreSubtitlePresentation last_presentation{};
  int last_width = 0, last_height = 0;
};

void close_ass(AssRenderer *ass) {
  if (ass->track) ass_free_track(ass->track);
  if (ass->renderer) ass_renderer_done(ass->renderer);
  if (ass->library) ass_library_done(ass->library);
  *ass = {};
}

void configure_ass_fonts(ASS_Renderer *renderer) {
#if defined(__ANDROID__)
  // Android has no Fontconfig provider. Use a readable system font for text
  // subtitles and ASS scripts without an attached font.
  constexpr const char *fonts[] = {
      "/system/fonts/NotoSansCJK-Regular.ttc",
      "/system/fonts/Roboto-Regular.ttf",
      "/system/fonts/DroidSans.ttf",
  };
  const char *fallback = nullptr;
  for (const char *font : fonts) {
    if (access(font, R_OK) == 0) {
      fallback = font;
      break;
    }
  }
  ass_set_fonts(renderer, fallback, "sans-serif", ASS_FONTPROVIDER_NONE,
                nullptr, 1);
#else
  ass_set_fonts(renderer, nullptr, "sans-serif", ASS_FONTPROVIDER_AUTODETECT,
                nullptr, 1);
#endif
}

bool open_ass(AssRenderer *ass, AVFormatContext *format, int stream_index) {
  AssRenderer replacement;
  replacement.library = ass_library_init();
  if (!replacement.library) return false;
  replacement.renderer = ass_renderer_init(replacement.library);
  replacement.track = ass_new_track(replacement.library);
  if (!replacement.renderer || !replacement.track) {
    close_ass(&replacement);
    return false;
  }
  const auto *parameters = format->streams[stream_index]->codecpar;
  if (parameters->extradata && parameters->extradata_size > 0)
    ass_process_codec_private(replacement.track,
                              reinterpret_cast<const char *>(parameters->extradata),
                              parameters->extradata_size);
  for (unsigned int index = 0; index < format->nb_streams; ++index) {
    const AVStream *stream = format->streams[index];
    if (stream->codecpar->codec_type != AVMEDIA_TYPE_ATTACHMENT ||
        stream->codecpar->extradata_size <= 0 ||
        stream->codecpar->extradata_size > 8 * 1024 * 1024) continue;
    const AVDictionaryEntry *name = av_dict_get(stream->metadata,
                                                "filename", nullptr, 0);
    if (name && name->value)
      ass_add_font(replacement.library, name->value,
                   reinterpret_cast<const char *>(stream->codecpar->extradata),
                   stream->codecpar->extradata_size);
  }
  configure_ass_fonts(replacement.renderer);
  replacement.stream = stream_index;
  close_ass(ass);
  *ass = replacement;
  return true;
}

bool open_text_ass(AssRenderer *ass, const AVCodecContext *decoder,
                   int stream_index) {
  if (!decoder || !decoder->subtitle_header ||
      decoder->subtitle_header_size <= 0) return false;
  AssRenderer replacement;
  replacement.library = ass_library_init();
  if (!replacement.library) return false;
  replacement.renderer = ass_renderer_init(replacement.library);
  replacement.track = ass_new_track(replacement.library);
  if (!replacement.renderer || !replacement.track) {
    close_ass(&replacement);
    return false;
  }
  ass_process_codec_private(replacement.track,
                            reinterpret_cast<const char *>(
                                decoder->subtitle_header),
                            decoder->subtitle_header_size);
  configure_ass_fonts(replacement.renderer);
  replacement.stream = stream_index;
  replacement.plain_text = true;
  if (ass_track_set_feature(replacement.track, ASS_FEATURE_WRAP_UNICODE, 1) != 0) {
    close_ass(&replacement);
    return false;
  }
  close_ass(ass);
  *ass = replacement;
  return true;
}

int decode_text_subtitle(Decoder &decoder, const AVPacket *packet,
                         AVRational time_base, AssRenderer *ass) {
  AVSubtitle subtitle{};
  int got = 0;
  const int result = avcodec_decode_subtitle2(decoder.context, &subtitle,
                                               &got, packet);
  if (result < 0) return result;
  if (!got) return 0;
  int64_t start_ms = subtitle.pts == AV_NOPTS_VALUE ?
      (packet->pts == AV_NOPTS_VALUE ? 0 :
       av_rescale_q(packet->pts, time_base, AVRational{1, 1000})) :
      subtitle.pts / 1000;
  start_ms += subtitle.start_display_time;
  int64_t duration_ms = 0;
  if (subtitle.end_display_time > subtitle.start_display_time)
    duration_ms = subtitle.end_display_time - subtitle.start_display_time;
  else if (packet->duration > 0)
    duration_ms = av_rescale_q(packet->duration, time_base,
                               AVRational{1, 1000});
  if (duration_ms <= 0) duration_ms = 5000;
  for (unsigned int index = 0; index < subtitle.num_rects; ++index) {
    const auto *rect = subtitle.rects[index];
    if (rect->type != SUBTITLE_ASS || !rect->ass) continue;
    ass_process_chunk(ass->track, rect->ass, std::strlen(rect->ass),
                      start_ms, duration_ms);
  }
  avsubtitle_free(&subtitle);
  return 0;
}

bool open_external_ass(AssRenderer *ass, const std::vector<char> &script,
                       int stream_index) {
  if (script.empty()) return false;
  AssRenderer replacement;
  replacement.library = ass_library_init();
  if (!replacement.library) return false;
  replacement.renderer = ass_renderer_init(replacement.library);
  std::vector<char> mutable_script = script;
  mutable_script.push_back('\0');
  replacement.track = ass_read_memory(replacement.library,
                                      mutable_script.data(), script.size(),
                                      nullptr);
  if (!replacement.renderer || !replacement.track ||
      replacement.track->n_events <= 0) {
    close_ass(&replacement);
    return false;
  }
  configure_ass_fonts(replacement.renderer);
  replacement.stream = stream_index;
  replacement.external = true;
  close_ass(ass);
  *ass = replacement;
  return true;
}

bool open_external_text(AssRenderer *ass, const std::vector<char> &header,
                        const std::vector<ExternalTextCue> &cues,
                        int stream_index) {
  if (header.empty() || cues.empty()) return false;
  AssRenderer replacement;
  replacement.library = ass_library_init();
  if (!replacement.library) return false;
  replacement.renderer = ass_renderer_init(replacement.library);
  replacement.track = ass_new_track(replacement.library);
  if (!replacement.renderer || !replacement.track) {
    close_ass(&replacement);
    return false;
  }
  ass_process_codec_private(replacement.track, header.data(), header.size());
  for (const auto &cue : cues) {
    std::string chunk = cue.ass_chunk;
    ass_process_chunk(replacement.track, chunk.data(), chunk.size(),
                      cue.start_ms, cue.duration_ms);
  }
  if (replacement.track->n_events <= 0) {
    close_ass(&replacement);
    return false;
  }
  configure_ass_fonts(replacement.renderer);
  replacement.stream = stream_index;
  replacement.plain_text = true;
  if (ass_track_set_feature(replacement.track, ASS_FEATURE_WRAP_UNICODE, 1) != 0) {
    close_ass(&replacement);
    return false;
  }
  replacement.external = true;
  close_ass(ass);
  *ass = replacement;
  return true;
}

void process_ass(AssRenderer *ass, const AVPacket *packet,
                 AVRational time_base) {
  if (!ass->track || !packet->data || packet->size <= 0) return;
  const int64_t start = packet->pts == AV_NOPTS_VALUE ? 0 :
      av_rescale_q(packet->pts, time_base, AVRational{1, 1000});
  const int64_t duration = packet->duration > 0 ?
      av_rescale_q(packet->duration, time_base, AVRational{1, 1000}) : 5000;
  ass_process_chunk(ass->track,
                    reinterpret_cast<char *>(packet->data), packet->size,
                    start, duration);
}

// Both output paths enter here, in the subtitle mutex, before rasterization.
void apply_subtitle_presentation(AssRenderer *ass, int width, int height,
                                const RillightCoreSubtitlePresentation &p) {
  if (!ass->track) return;
  if (ass->last_width == width && ass->last_height == height &&
      std::memcmp(&ass->last_presentation, &p, sizeof(p)) == 0) return;
  ass->last_presentation = p;
  ass->last_width = width; ass->last_height = height;
  ass_set_storage_size(ass->renderer, width, height);
  ass_set_frame_size(ass->renderer, width, height);
  ass_set_font_scale(ass->renderer, 1.0);
  ass_set_pixel_aspect(ass->renderer, 0);
  ass_set_selective_style_override_enabled(ass->renderer, ASS_OVERRIDE_DEFAULT);
  if (!p.enabled || (!ass->plain_text && p.original_ass)) return;
  ass_set_pixel_aspect(ass->renderer,
      (p.display_width / p.display_height) / (static_cast<double>(width) / height));
  // libass's selective user style uses a 288-high virtual canvas, independent
  // of the script PlayRes. Pixel aspect is kept at 1: no stretched glyphs.
  const double size = std::min(p.font_size * p.user_scale,
                               p.display_height * 0.18);
  ASS_Style style{};
  // libass 0.17.5 copies FontName even when only size fields are selected.
  style.FontName = const_cast<char *>("sans-serif");
  style.FontSize = size * 288.0 / p.display_height;
  style.ScaleX = style.ScaleY = 1.0;
  style.MarginL = style.MarginR = static_cast<int>(
      p.safe_horizontal * ass->track->PlayResX / p.display_width);
  style.MarginV = static_cast<int>(p.safe_vertical * ass->track->PlayResY / p.display_height);
  int bits = ASS_OVERRIDE_BIT_FONT_SIZE_FIELDS;
  if (ass->plain_text) bits |= ASS_OVERRIDE_BIT_MARGINS;
  ass_set_selective_style_override(ass->renderer, &style);
  ass_set_selective_style_override_enabled(ass->renderer, bits);
}

void blend_ass(RillightCoreFrame *frame, AssRenderer *ass) {
  if (!ass->track || !frame || frame->pts_us < 0) return;
  ass_set_storage_size(ass->renderer, frame->width, frame->height);
  ass_set_frame_size(ass->renderer, frame->width, frame->height);
  int changed = 0;
  const ASS_Image *image = ass_render_frame(ass->renderer, ass->track,
                                            frame->pts_us / 1000, &changed);
  for (; image; image = image->next) {
    if (!image->bitmap || image->w <= 0 || image->h <= 0 ||
        image->stride < image->w) continue;
    const uint32_t color = image->color;
    const unsigned int opacity = 255 - (color & 0xff);
    for (int row = 0; row < image->h; ++row) {
      const int y = image->dst_y + row;
      if (y < 0 || y >= frame->height) continue;
      for (int column = 0; column < image->w; ++column) {
        const int x = image->dst_x + column;
        if (x < 0 || x >= frame->width) continue;
        const unsigned int alpha =
            image->bitmap[static_cast<size_t>(row) * image->stride + column] *
            opacity / 255;
        if (!alpha) continue;
        uint8_t *pixel = frame->data + static_cast<size_t>(y) *
                                        frame->stride + x * 4;
        for (int channel = 0; channel < 3; ++channel) {
          const unsigned int foreground =
              (color >> (24 - channel * 8)) & 0xff;
          pixel[channel] = static_cast<uint8_t>(
              (foreground * alpha + pixel[channel] * (255 - alpha) + 127) /
              255);
        }
        pixel[3] = 255;
      }
    }
  }
}
#else
struct AssRenderer {};
void close_ass(AssRenderer *) {}
void blend_ass(RillightCoreFrame *, AssRenderer *) {}
void apply_subtitle_presentation(AssRenderer *, int, int,
    const RillightCoreSubtitlePresentation &) {}
#endif

void blend_subtitles(RillightCoreFrame *frame,
                     const std::vector<SubtitleCue> &cues) {
  if (!frame || frame->type != RILLIGHT_CORE_VIDEO_RGBA || frame->pts_us < 0)
    return;
  for (const auto &cue : cues) {
    if (frame->pts_us < cue.start_us || frame->pts_us >= cue.end_us) continue;
    for (const auto &bitmap : cue.bitmaps) {
      for (int row = 0; row < bitmap.height; ++row) {
        const int y = bitmap.y + row;
        if (y < 0 || y >= frame->height) continue;
        for (int column = 0; column < bitmap.width; ++column) {
          const int x = bitmap.x + column;
          if (x < 0 || x >= frame->width) continue;
          const uint8_t index = bitmap.indices[
              static_cast<size_t>(row) * bitmap.width + column];
          if (index >= bitmap.palette.size()) continue;
          const uint32_t color = bitmap.palette[index];
          const unsigned int alpha = color >> 24;
          if (!alpha) continue;
          uint8_t *pixel = frame->data + static_cast<size_t>(y) *
                                          frame->stride + x * 4;
          for (int channel = 0; channel < 3; ++channel) {
            const unsigned int foreground =
                (color >> (16 - channel * 8)) & 0xff;
            pixel[channel] = static_cast<uint8_t>(
                (foreground * alpha + pixel[channel] * (255 - alpha) + 127) /
                255);
          }
          pixel[3] = 255;
        }
      }
    }
  }
}

void render_gpu_subtitles(VideoOutputFrame* frame,
                          const std::vector<SubtitleCue>& cues, AssRenderer* ass,
                          BitmapSubtitleOverlayCache* cache) {
  // Bitmap display sets remain unchanged across video frames. Share immutable
  // composed pixels until a cue changes; animated ASS must still render at PTS.
  bool cacheable = true;
#if RILLIGHT_HAVE_LIBASS
  cacheable = !ass->track;
#endif
  auto key = bitmap_subtitle_key(cues, frame->pts_us, frame->width, frame->height);
  if (cacheable && cache->valid && cache->key == key) {
    frame->subtitle_pixels = cache->pixels;
    frame->subtitle_overlay = cache->overlay;
    if (frame->subtitle_pixels)
      frame->data_size += static_cast<int>(frame->subtitle_pixels->size());
    return;
  }
  const auto remember = [&] {
    cache->valid = cacheable;
    cache->key = std::move(key);
    cache->pixels = cacheable ? frame->subtitle_pixels : nullptr;
    cache->overlay = cacheable ? frame->subtitle_overlay : RillightCoreSubtitleOverlay{};
  };
  int left = frame->width, top = frame->height, right = 0, bottom = 0;
  const auto include = [&](int x, int y, int width, int height) {
    if (width <= 0 || height <= 0) return;
    const int x0 = std::clamp(x, 0, frame->width);
    const int y0 = std::clamp(y, 0, frame->height);
    const int x1 = static_cast<int>(std::clamp<int64_t>(static_cast<int64_t>(x) + width, 0, frame->width));
    const int y1 = static_cast<int>(std::clamp<int64_t>(static_cast<int64_t>(y) + height, 0, frame->height));
    if (x0 >= x1 || y0 >= y1) return;
    left = std::min(left, x0); top = std::min(top, y0);
    right = std::max(right, x1); bottom = std::max(bottom, y1);
  };
  for (const auto& cue : cues) {
    if (frame->pts_us < cue.start_us || frame->pts_us >= cue.end_us) continue;
    for (const auto& bitmap : cue.bitmaps) include(bitmap.x, bitmap.y, bitmap.width, bitmap.height);
  }
#if RILLIGHT_HAVE_LIBASS
  const ASS_Image* images = nullptr;
  if (ass->track && frame->pts_us >= 0) {
    ass_set_storage_size(ass->renderer, frame->width, frame->height);
    ass_set_frame_size(ass->renderer, frame->width, frame->height);
    int changed = 0;
    images = ass_render_frame(ass->renderer, ass->track, frame->pts_us / 1000, &changed);
    for (auto* image = images; image; image = image->next)
      if (image->bitmap && image->stride >= image->w)
        include(image->dst_x, image->dst_y, image->w, image->h);
  }
#else
  (void)ass;
#endif
  if (left >= right || top >= bottom) { remember(); return; }
  const int width = right - left, height = bottom - top;
  const size_t bytes = static_cast<size_t>(width) * height * 4;
  if (bytes > kMaxVideoBytes) return;
  frame->subtitle_pixels = std::make_shared<std::vector<uint8_t>>(bytes, 0);
  frame->subtitle_overlay = {sizeof(RillightCoreSubtitleOverlay), left, top, width, height, width * 4,
                             frame->subtitle_pixels->data()};
  frame->data_size += static_cast<int>(bytes);
  const auto blend = [&](int64_t x, int64_t y, unsigned int color, unsigned int alpha) {
    if (x < left || x >= right || y < top || y >= bottom || !alpha) return;
    auto* pixel = frame->subtitle_pixels->data() +
        (static_cast<size_t>(y - top) * width + static_cast<size_t>(x - left)) * 4;
    for (int channel = 0; channel < 3; ++channel) {
      const unsigned int foreground = (color >> (16 - channel * 8)) & 255;
      pixel[channel] = static_cast<uint8_t>((foreground * alpha + pixel[channel] * (255 - alpha) + 127) / 255);
    }
    pixel[3] = static_cast<uint8_t>(alpha + (pixel[3] * (255 - alpha) + 127) / 255);
  };
  for (const auto& cue : cues) {
    if (frame->pts_us < cue.start_us || frame->pts_us >= cue.end_us) continue;
    for (const auto& bitmap : cue.bitmaps) {
      for (int row = 0; row < bitmap.height; ++row) {
        for (int column = 0; column < bitmap.width; ++column) {
          const auto index = bitmap.indices[static_cast<size_t>(row) * bitmap.width + column];
          if (index >= bitmap.palette.size()) continue;
          const auto color = bitmap.palette[index];
          blend(static_cast<int64_t>(bitmap.x) + column, static_cast<int64_t>(bitmap.y) + row, color, color >> 24);
        }
      }
    }
  }
#if RILLIGHT_HAVE_LIBASS
  for (auto* image = images; image; image = image->next) {
    if (!image->bitmap || image->w <= 0 || image->h <= 0 || image->stride < image->w) continue;
    const unsigned int opacity = 255 - (image->color & 255);
    for (int row = 0; row < image->h; ++row) {
      for (int column = 0; column < image->w; ++column) {
        const unsigned int alpha = image->bitmap[static_cast<size_t>(row) * image->stride + column] * opacity / 255;
        blend(static_cast<int64_t>(image->dst_x) + column, static_cast<int64_t>(image->dst_y) + row,
              image->color >> 8, alpha);
      }
    }
  }
#endif
  remember();
}

int decode_bitmap_subtitle(Decoder &decoder, const AVPacket *packet,
                           AVRational time_base,
                           std::vector<SubtitleCue> *cues) {
  AVSubtitle subtitle{};
  int got = 0;
  const int result = avcodec_decode_subtitle2(decoder.context, &subtitle,
                                               &got, packet);
  if (result < 0) return result;
  if (!got) return 0;
  int64_t start = subtitle.pts;
  if (start == AV_NOPTS_VALUE && packet->pts != AV_NOPTS_VALUE)
    start = av_rescale_q(packet->pts, time_base, AVRational{1, 1000000});
  if (start == AV_NOPTS_VALUE) start = 0;
  SubtitleCue cue;
  cue.start_us = start + subtitle.start_display_time * 1000LL;
  cue.end_us = start + subtitle.end_display_time * 1000LL;
  if (cue.end_us <= cue.start_us) cue.end_us = cue.start_us + 5000000;
  if (decoder.context->codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE)
    end_pgs_display(*cues, cue.start_us);
  size_t cue_bytes = 0;
  for (unsigned int index = 0; index < subtitle.num_rects; ++index) {
    const AVSubtitleRect *rect = subtitle.rects[index];
    if (rect->type != SUBTITLE_BITMAP || rect->w <= 0 || rect->h <= 0 ||
        rect->w > 8192 || rect->h > 8192 || !rect->data[0] ||
        !rect->data[1] || rect->linesize[0] < rect->w ||
        static_cast<size_t>(rect->w) * rect->h > 4u * 1024u * 1024u ||
        cue_bytes + static_cast<size_t>(rect->w) * rect->h >
            8u * 1024u * 1024u)
      continue;
    SubtitleBitmap bitmap;
    bitmap.x = rect->x;
    bitmap.y = rect->y;
    bitmap.width = rect->w;
    bitmap.height = rect->h;
    bitmap.indices.resize(static_cast<size_t>(rect->w) * rect->h);
    for (int row = 0; row < rect->h; ++row)
      std::memcpy(bitmap.indices.data() + static_cast<size_t>(row) * rect->w,
                  rect->data[0] + static_cast<size_t>(row) * rect->linesize[0],
                  rect->w);
    const int colors = std::clamp(rect->nb_colors, 0, 256);
    const auto *palette = reinterpret_cast<const uint32_t *>(rect->data[1]);
    bitmap.palette.assign(palette, palette + colors);
    cue_bytes += bitmap.indices.size();
    cue.bitmaps.push_back(std::move(bitmap));
  }
  avsubtitle_free(&subtitle);
  if (!cue.bitmaps.empty()) {
    static std::atomic<uint64_t> next_identity{0};
    cue.identity = next_identity.fetch_add(1, std::memory_order_relaxed) + 1;
    cues->push_back(std::move(cue));
    if (cues->size() > 8) cues->erase(cues->begin());
  }
  return 0;
}

void close_audio_filter(AudioFilter *filter) {
  avfilter_graph_free(&filter->graph);
  av_channel_layout_uninit(&filter->input_layout);
  filter->source = nullptr;
  filter->sink = nullptr;
  filter->input_rate = 0;
  filter->input_format = AV_SAMPLE_FMT_NONE;
  filter->media_anchor = AV_NOPTS_VALUE;
  filter->output_anchor = AV_NOPTS_VALUE;
  filter->next_media_pts = AV_NOPTS_VALUE;
}

struct RillightCoreImpl {
  explicit RillightCoreImpl(const RillightCoreIo &source_io) : io(source_io) {}
  RillightCoreIo io;
  std::unique_ptr<LoopbackIo> owned_loopback;
  std::mutex mutex;
  std::mutex lifecycle_mutex;
  std::mutex subtitle_mutex;
  AssRenderer ass;
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
  double video_frame_rate = 0;
  int audio_index = -1;
  bool is_mp4_container = false;
  int video_track_id = -1;
  int audio_track_id = -1;
  int subtitle_index = -1;
  int requested_audio = -1;
  bool audio_change = false;
  int requested_subtitle = -1;
  bool subtitle_change = false;
  bool external_subtitle_pending = false;
  std::string requested_external_subtitle;
  int64_t seek_target = -1;
  int64_t duration = -1;
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
  double volume = 1.0;
  bool external_audio_speed = false;
  double requested_speed = 1.0;
  bool speed_change = false;
  RillightCoreHardware hardware_preference = RILLIGHT_CORE_HW_NONE;
  std::shared_ptr<void> android_window;
  std::atomic<uint32_t> android_dovi_profiles{0};
  bool allow_software_fallback = true;
  size_t video_bytes = 0;
  size_t audio_bytes = 0;
  std::string url;
};

// Read under core->mutex. Device position reports arrive at audio packet/event
// boundaries. Interpolate between them so video deadlines do not move in
// steps, but never run beyond media already submitted to the audio device.
int64_t playback_position(const RillightCoreImpl *core,
                          Clock::time_point now = Clock::now()) {
  if (core->state != RILLIGHT_CORE_PLAYING) return core->base_position;
  const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
      now - core->base_time).count();
  const int64_t position = core->base_position + static_cast<int64_t>(
      std::max<int64_t>(0, elapsed) * core->speed);
  return core->audio_clock_active
      ? std::min(position, std::max(core->base_position, core->audio_clock_limit))
      : position;
}

#if RILLIGHT_HAVE_LIBASS
int read_external_ass(RillightCoreImpl *core, const std::string &url,
                      std::vector<char> *script) {
  void *handle = core->io.open(core->io.opaque, url.c_str(), AVIO_FLAG_READ);
  if (!handle) return AVERROR(ENOENT);
  std::vector<char> bytes;
  uint8_t buffer[kIoBufferSize];
  int result = 0;
  auto progress_deadline = Clock::now() + std::chrono::seconds(5);
  while (!core->stop) {
    const int count = core->io.read(core->io.opaque, handle, buffer,
                                    sizeof(buffer));
    if (count == AVERROR(EAGAIN) && Clock::now() < progress_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
      continue;
    }
    // AVIO returns AVERROR_EOF for a complete HTTP resource. The in-memory
    // test source returns zero, so accept both successful EOF forms.
    if (count == 0 || count == AVERROR_EOF) break;
    if (count < 0) { result = count; break; }
    if (count > static_cast<int>(sizeof(buffer))) {
      result = AVERROR(EINVAL);
      break;
    }
    if (bytes.size() + static_cast<size_t>(count) >
        kMaxExternalSubtitleBytes) {
      result = AVERROR(EFBIG);
      break;
    }
    bytes.insert(bytes.end(), reinterpret_cast<char *>(buffer),
                 reinterpret_cast<char *>(buffer) + count);
    progress_deadline = Clock::now() + std::chrono::seconds(5);
  }
  core->io.close(core->io.opaque, handle);
  if (core->stop) return AVERROR_EXIT;
  if (result < 0) return result;
  if (bytes.empty()) return AVERROR_INVALIDDATA;
  *script = std::move(bytes);
  return 0;
}

struct SubtitleMemoryInput {
  RillightCoreImpl *core;
  const std::vector<char> *bytes;
  size_t offset = 0;
};

int subtitle_memory_read(void *opaque, uint8_t *buffer, int size) {
  auto *input = static_cast<SubtitleMemoryInput *>(opaque);
  if (input->core->stop) return AVERROR_EXIT;
  const size_t count = std::min(static_cast<size_t>(size),
                                input->bytes->size() - input->offset);
  if (!count) return AVERROR_EOF;
  std::memcpy(buffer, input->bytes->data() + input->offset, count);
  input->offset += count;
  return static_cast<int>(count);
}

int64_t subtitle_memory_seek(void *opaque, int64_t offset, int whence) {
  auto *input = static_cast<SubtitleMemoryInput *>(opaque);
  if (input->core->stop) return AVERROR_EXIT;
  if ((whence & ~AVSEEK_FORCE) == AVSEEK_SIZE)
    return static_cast<int64_t>(input->bytes->size());
  int64_t base = 0;
  switch (whence & ~AVSEEK_FORCE) {
    case SEEK_CUR: base = static_cast<int64_t>(input->offset); break;
    case SEEK_END: base = static_cast<int64_t>(input->bytes->size()); break;
    case SEEK_SET: break;
    default: return AVERROR(EINVAL);
  }
  if ((offset < 0 && offset < -base) ||
      (offset > 0 && base > INT64_MAX - offset)) return AVERROR(EINVAL);
  const int64_t target = base + offset;
  if (target < 0 || target > static_cast<int64_t>(input->bytes->size()))
    return AVERROR(EINVAL);
  input->offset = static_cast<size_t>(target);
  return target;
}

int parse_external_text(RillightCoreImpl *core,
                        const std::vector<char> &bytes, AVCodecID codec,
                        std::vector<char> *header,
                        std::vector<ExternalTextCue> *cues) {
  const char *name = codec == AV_CODEC_ID_SUBRIP ? "srt" :
                     codec == AV_CODEC_ID_WEBVTT ? "webvtt" : nullptr;
  if (!name || bytes.empty()) return AVERROR(EINVAL);
  const AVInputFormat *input_format = av_find_input_format(name);
  const AVCodec *avcodec = avcodec_find_decoder(codec);
  if (!input_format || !avcodec) return AVERROR_DECODER_NOT_FOUND;
  SubtitleMemoryInput input{core, &bytes};
  auto *buffer = static_cast<uint8_t *>(av_malloc(kIoBufferSize));
  if (!buffer) return AVERROR(ENOMEM);
  AVIOContext *avio = avio_alloc_context(buffer, kIoBufferSize, 0, &input,
                                        subtitle_memory_read, nullptr,
                                        subtitle_memory_seek);
  if (!avio) { av_free(buffer); return AVERROR(ENOMEM); }
  AVFormatContext *format = avformat_alloc_context();
  AVCodecContext *decoder = nullptr;
  AVPacket *packet = nullptr;
  int result = AVERROR(ENOMEM);
  if (!format) goto finish_external_text;
  format->pb = avio;
  format->flags |= AVFMT_FLAG_CUSTOM_IO;
  result = avformat_open_input(&format, nullptr, input_format, nullptr);
  if (result < 0) goto finish_external_text;
  result = avformat_find_stream_info(format, nullptr);
  if (result < 0) goto finish_external_text;
  {
    const int stream_index = av_find_best_stream(format,
        AVMEDIA_TYPE_SUBTITLE, -1, -1, nullptr, 0);
    if (stream_index < 0) { result = stream_index; goto finish_external_text; }
    const AVStream *stream = format->streams[stream_index];
    if (stream->codecpar->codec_id != codec) {
      result = AVERROR_INVALIDDATA;
      goto finish_external_text;
    }
    decoder = avcodec_alloc_context3(avcodec);
    if (!decoder) { result = AVERROR(ENOMEM); goto finish_external_text; }
    result = avcodec_parameters_to_context(decoder, stream->codecpar);
    if (result < 0) goto finish_external_text;
    decoder->pkt_timebase = stream->time_base;
    result = avcodec_open2(decoder, avcodec, nullptr);
    if (result < 0) goto finish_external_text;
    if (!decoder->subtitle_header || decoder->subtitle_header_size <= 0) {
      result = AVERROR_INVALIDDATA;
      goto finish_external_text;
    }
    header->assign(decoder->subtitle_header,
                   decoder->subtitle_header + decoder->subtitle_header_size);
    packet = av_packet_alloc();
    if (!packet) { result = AVERROR(ENOMEM); goto finish_external_text; }
    size_t total_chunk_bytes = header->size();
    while ((result = av_read_frame(format, packet)) >= 0) {
      if (core->stop) { result = AVERROR_EXIT; break; }
      if (packet->stream_index == stream_index) {
        AVSubtitle subtitle{};
        int got = 0;
        const int decoded = avcodec_decode_subtitle2(decoder, &subtitle,
                                                     &got, packet);
        if (decoded < 0) {
          avsubtitle_free(&subtitle);
          result = decoded;
          break;
        }
        if (got) {
          int64_t start_ms = subtitle.pts == AV_NOPTS_VALUE ?
              (packet->pts == AV_NOPTS_VALUE ? 0 :
               av_rescale_q(packet->pts, stream->time_base,
                            AVRational{1, 1000})) : subtitle.pts / 1000;
          start_ms += subtitle.start_display_time;
          int64_t duration_ms = subtitle.end_display_time >
                                subtitle.start_display_time ?
              subtitle.end_display_time - subtitle.start_display_time :
              av_rescale_q(packet->duration, stream->time_base,
                           AVRational{1, 1000});
          if (start_ms < 0 || duration_ms <= 0) {
            avsubtitle_free(&subtitle);
            result = AVERROR_INVALIDDATA;
            break;
          }
          for (unsigned int index = 0; index < subtitle.num_rects; ++index) {
            const AVSubtitleRect *rect = subtitle.rects[index];
            if (rect->type != SUBTITLE_ASS || !rect->ass) continue;
            const size_t length = std::strlen(rect->ass);
            if (cues->size() >= 10000 ||
                length > kMaxExternalSubtitleBytes - total_chunk_bytes) {
              result = AVERROR(EFBIG);
              break;
            }
            cues->push_back({start_ms, duration_ms, rect->ass});
            total_chunk_bytes += length;
          }
        }
        avsubtitle_free(&subtitle);
      }
      av_packet_unref(packet);
      if (result < 0) break;
    }
    if (result == AVERROR_EOF && !cues->empty()) result = 0;
    else if (result == AVERROR_EOF) result = AVERROR_INVALIDDATA;
  }
finish_external_text:
  av_packet_free(&packet);
  avcodec_free_context(&decoder);
  if (format) avformat_close_input(&format);
  if (avio) av_freep(&avio->buffer);
  avio_context_free(&avio);
  return result;
}

AVCodecID external_subtitle_codec(const std::string &url) {
  std::string path = url.substr(0, url.find_first_of("?#"));
  std::transform(path.begin(), path.end(), path.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  const auto ends_with = [&path](const char *suffix) {
    const size_t length = std::strlen(suffix);
    return path.size() >= length &&
           path.compare(path.size() - length, length, suffix) == 0;
  };
  if (ends_with(".srt")) return AV_CODEC_ID_SUBRIP;
  if (ends_with(".vtt") || ends_with(".webvtt")) return AV_CODEC_ID_WEBVTT;
  return AV_CODEC_ID_ASS;
}

void load_external_ass(RillightCoreImpl *core, uint64_t session,
                       std::string url) {
  std::vector<char> source;
  int result = read_external_ass(core, url, &source);
  const size_t source_bytes = source.size();
  const AVCodecID codec = external_subtitle_codec(url);
  std::vector<char> script;
  std::vector<ExternalTextCue> cues;
  if (result >= 0) {
    if (codec == AV_CODEC_ID_ASS) script = std::move(source);
    else result = parse_external_text(core, source, codec, &script, &cues);
  }
  if (result >= 0) {
    AssRenderer probe;
    const bool valid = codec == AV_CODEC_ID_ASS ?
        open_external_ass(&probe, script, -1) :
        open_external_text(&probe, script, cues, -1);
    if (!valid)
      result = AVERROR_INVALIDDATA;
    close_ass(&probe);
  }
  {
    std::lock_guard lock(core->mutex);
    if (core->stop || core->session != session) return;
    if (result >= 0 &&
        (core->external_subtitles.size() >= kMaxExternalSubtitleTracks ||
         core->external_subtitle_bytes + source_bytes >
             kMaxExternalSubtitleTotalBytes ||
         core->embedded_stream_count >= kExternalSubtitleStreamBase))
      result = AVERROR(EFBIG);
    if (result >= 0) {
      const int index = kExternalSubtitleStreamBase +
          static_cast<int>(core->external_subtitles.size());
      RillightCoreTrack track{};
      track.struct_size = sizeof(track);
      track.stream_index = index;
      track.type = RILLIGHT_CORE_TRACK_SUBTITLE;
      track.codec_id = codec;
      std::snprintf(track.codec_name, sizeof(track.codec_name), "%s",
                    avcodec_get_name(codec));
      std::snprintf(track.title, sizeof(track.title), "External %s",
                    codec == AV_CODEC_ID_ASS ? "ASS" :
                    codec == AV_CODEC_ID_SUBRIP ? "SRT" : "WebVTT");
      track.is_external = 1;
      core->tracks.push_back(track);
      core->external_subtitle_bytes += source_bytes;
      core->external_subtitles.push_back(
          {index, codec,
           std::make_shared<const std::vector<char>>(std::move(script)),
           std::make_shared<const std::vector<ExternalTextCue>>(std::move(cues)),
           source_bytes});
    }
    core->error = result;
    core->external_subtitle_pending = false;
    core->requested_external_subtitle.clear();
  }
  core->wake.notify_all();
}
#endif

RillightCoreImpl *impl(RillightCore *core) {
  return reinterpret_cast<RillightCoreImpl *>(core);
}

void clear_queue(std::deque<RillightCoreFrame *> &queue, size_t &bytes) {
  while (!queue.empty()) {
    auto *frame = queue.front();
    queue.pop_front();
    rillight_core_release_frame(frame);
  }
  bytes = 0;
}

void reset_frames(RillightCoreImpl *core) {
  rillight_core_release_frame(core->displayed_clean);
  core->displayed_clean = nullptr;
  core->subtitle_redraw = false;
  rillight_core_release_frame(core->subtitle_preview);
  core->subtitle_preview = nullptr;
  clear_queue(core->video, core->video_bytes);
  clear_queue(core->audio, core->audio_bytes);
  core->first_video = false;
  core->first_audio = false;
  core->eof = false;
  core->input_exhausted = false;
  core->output_drained = false;
  core->audio_clock_active = false;
  core->audio_clock_limit = 0;
  core->audio_clock_handed_off = false;
  core->paused_video_frame_emitted = false;
  core->io_fatal_error = 0;
}

bool accept_operation(RillightCoreImpl *core, uint64_t operation) {
  if (!operation || operation <= core->operation ||
      core->state == RILLIGHT_CORE_CLOSING) {
    return false;
  }
  core->operation = operation;
  return true;
}

int interrupt_read(void *opaque) {
  auto *core = static_cast<RillightCoreImpl *>(opaque);
  return core->stop.load() || core->decode_abort.load() ||
         core->timeline_signal.load() != core->active_read_timeline.load();
}

int fill_decrypted(Source *source) {
  if (source->encrypted_eof && !source->ciphertext_size)
    return AVERROR_EOF;
  while (!source->encrypted_eof && source->ciphertext_size < 32) {
    const int capacity = static_cast<int>(source->ciphertext.size() -
                                          source->ciphertext_size);
    const int read = source->io.read(source->io.opaque, source->handle,
                                     source->ciphertext.data() +
                                         source->ciphertext_size,
                                     capacity);
    if (read > capacity) return AVERROR(EIO);
    if (read < 0) return read;
    if (read == 0) {
      source->encrypted_eof = true;
      break;
    }
    source->ciphertext_size += read;
  }
  if (source->encrypted_eof &&
      (source->ciphertext_size == 0 || source->ciphertext_size % 16 != 0))
    return AVERROR_INVALIDDATA;
  size_t blocks = source->ciphertext_size / 16;
  if (!source->encrypted_eof) --blocks;  // Keep the final block for PKCS#7.
  if (!blocks) return AVERROR(EAGAIN);
  const size_t decrypted_size = blocks * 16;
  av_aes_crypt(source->aes, source->plaintext.data(),
               source->ciphertext.data(), static_cast<int>(blocks),
               source->iv.data(), 1);
  source->plaintext_size = decrypted_size;
  source->plaintext_offset = 0;
  if (source->encrypted_eof) {
    const uint8_t padding = source->plaintext[decrypted_size - 1];
    if (padding == 0 || padding > 16 ||
        !std::all_of(source->plaintext.data() + decrypted_size - padding,
                     source->plaintext.data() + decrypted_size,
                     [padding](uint8_t byte) { return byte == padding; }))
      return AVERROR_INVALIDDATA;
    source->plaintext_size -= padding;
  }
  source->ciphertext_size -= decrypted_size;
  if (source->ciphertext_size)
    std::memmove(source->ciphertext.data(),
                 source->ciphertext.data() + decrypted_size,
                 source->ciphertext_size);
  return source->plaintext_size ? 0 : AVERROR_EOF;
}

int source_read(void *opaque, uint8_t *buffer, int size) {
  auto *source = static_cast<Source *>(opaque);
  const uint64_t read_timeline = source->timeline_signal->load();
  const auto record_error = [source, read_timeline](int result) {
    if (result < 0 && result != AVERROR_EOF &&
        result != AVERROR(EAGAIN) && result != AVERROR_EXIT &&
        source->timeline_signal->load() == read_timeline &&
        source->active_read_timeline->load() == read_timeline) {
      int expected = 0;
      source->fatal_error->compare_exchange_strong(expected, result);
    }
    return result;
  };
  if (!source->aes) {
    const int result = source->io.read(source->io.opaque, source->handle,
                                       buffer, size);
    if (result > size) return record_error(AVERROR(EIO));
    return record_error(result == 0 ? AVERROR_EOF : result);
  }
  int copied = 0;
  while (copied < size) {
    if (source->plaintext_offset == source->plaintext_size) {
      const int result = fill_decrypted(source);
      if (result < 0) {
        record_error(result);
        return copied ? copied : result;
      }
    }
    const size_t count = std::min<size_t>(
        size - copied, source->plaintext_size - source->plaintext_offset);
    std::memcpy(buffer + copied,
                source->plaintext.data() + source->plaintext_offset, count);
    copied += static_cast<int>(count);
    source->plaintext_offset += count;
    source->position += count;
  }
  return copied;
}

int64_t source_seek(void *opaque, int64_t offset, int whence) {
  auto *source = static_cast<Source *>(opaque);
  if (!source->aes) {
    const auto timeline = source->timeline_signal->load();
    const int64_t result = source->io.seek(source->io.opaque, source->handle, offset, whence);
    if (!(whence & AVSEEK_SIZE) && result < 0 && result != AVERROR(ENOSYS) &&
        result != AVERROR(EAGAIN) && result != AVERROR_EXIT &&
        source->timeline_signal->load() == timeline &&
        source->active_read_timeline->load() == timeline) {
      int expected = 0;
      source->fatal_error->compare_exchange_strong(expected, static_cast<int>(result));
    }
    return result;
  }
  if (whence == AVSEEK_SIZE)
    return source->io.seek(source->io.opaque, source->handle, offset, whence);
  if (whence == SEEK_CUR && offset == 0) return source->position;
  if (whence != SEEK_SET || offset != 0) return AVERROR(ENOSYS);
  const int64_t target = source->io.seek(source->io.opaque, source->handle,
                                         0, SEEK_SET);
  if (target != 0) return target < 0 ? target : AVERROR(EIO);
  source->iv = source->initial_iv;
  source->ciphertext_size = 0;
  source->plaintext_size = 0;
  source->plaintext_offset = 0;
  source->position = 0;
  source->encrypted_eof = false;
  return 0;
}

Source *open_source(RillightCoreImpl *core, const char *url, int flags) {
  auto source = std::make_unique<Source>();
  source->io = core->io;
  source->fatal_error = &core->io_fatal_error;
  source->timeline_signal = &core->timeline_signal;
  source->active_read_timeline = &core->active_read_timeline;
  source->handle = core->io.open(core->io.opaque, url, flags);
  if (!source->handle) return nullptr;
  auto *buffer = static_cast<unsigned char *>(av_malloc(kIoBufferSize));
  if (!buffer) {
    core->io.close(core->io.opaque, source->handle);
    return nullptr;
  }
  source->avio = avio_alloc_context(buffer, kIoBufferSize, 0, source.get(),
                                    source_read, nullptr, source_seek);
  if (!source->avio) {
    av_free(buffer);
    core->io.close(core->io.opaque, source->handle);
    return nullptr;
  }
  return source.release();
}

void close_source(Source *source) {
  if (!source) return;
  if (source->avio) {
    av_freep(&source->avio->buffer);
    avio_context_free(&source->avio);
  }
  source->io.close(source->io.opaque, source->handle);
  av_free(source->aes);
  delete source;
}

bool parse_aes_hex(const char *hex, uint8_t *bytes) {
  if (!hex || std::strlen(hex) != 32) return false;
  const auto digit = [](char value) -> int {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    return -1;
  };
  for (int index = 0; index < 16; ++index) {
    const int high = digit(hex[index * 2]);
    const int low = digit(hex[index * 2 + 1]);
    if (high < 0 || low < 0) return false;
    bytes[index] = static_cast<uint8_t>((high << 4) | low);
  }
  return true;
}

int nested_open(AVFormatContext *format, AVIOContext **avio,
                const char *url, int flags, AVDictionary **options) {
  auto *core = static_cast<RillightCoreImpl *>(format->opaque);
  const bool encrypted = std::strncmp(url, "crypto+", 7) == 0;
  if (encrypted && (flags & AVIO_FLAG_WRITE)) return AVERROR(EACCES);
  std::array<uint8_t, 16> key{};
  std::array<uint8_t, 16> iv{};
  if (encrypted) {
    const auto *key_option = options && *options
        ? av_dict_get(*options, "key", nullptr, 0) : nullptr;
    const auto *iv_option = options && *options
        ? av_dict_get(*options, "iv", nullptr, 0) : nullptr;
    if (!key_option || !iv_option ||
        !parse_aes_hex(key_option->value, key.data()) ||
        !parse_aes_hex(iv_option->value, iv.data()))
      return AVERROR_INVALIDDATA;
  }
  auto *source = open_source(core, encrypted ? url + 7 : url, flags);
  if (!source) return AVERROR(EACCES);
  if (encrypted) {
    source->aes = av_aes_alloc();
    if (!source->aes || av_aes_init(source->aes, key.data(), 128, 1) < 0) {
      close_source(source);
      return AVERROR(ENOMEM);
    }
    source->initial_iv = iv;
    source->iv = iv;
    source->ciphertext.resize(kIoBufferSize + 16);
    source->plaintext.resize(kIoBufferSize + 16);
    source->avio->seekable = 0;
  }
  *avio = source->avio;
  return 0;
}

int nested_close(AVFormatContext *, AVIOContext *avio) {
  close_source(static_cast<Source *>(avio->opaque));
  return 0;
}

AVHWDeviceType hardware_device_type(RillightCoreHardware hardware) {
  switch (hardware) {
    case RILLIGHT_CORE_HW_D3D11: return AV_HWDEVICE_TYPE_D3D11VA;
    case RILLIGHT_CORE_HW_VIDEOTOOLBOX: return AV_HWDEVICE_TYPE_VIDEOTOOLBOX;
    case RILLIGHT_CORE_HW_VAAPI: return AV_HWDEVICE_TYPE_VAAPI;
    case RILLIGHT_CORE_HW_MEDIACODEC: return AV_HWDEVICE_TYPE_MEDIACODEC;
    default: return AV_HWDEVICE_TYPE_NONE;
  }
}

const char *mediacodec_decoder_name(AVCodecID codec) {
  switch (codec) {
    case AV_CODEC_ID_H264: return "h264_mediacodec";
    case AV_CODEC_ID_HEVC: return "hevc_mediacodec";
    case AV_CODEC_ID_AV1: return "av1_mediacodec";
    case AV_CODEC_ID_VP8: return "vp8_mediacodec";
    case AV_CODEC_ID_VP9: return "vp9_mediacodec";
    case AV_CODEC_ID_MPEG2VIDEO: return "mpeg2_mediacodec";
    case AV_CODEC_ID_MPEG4: return "mpeg4_mediacodec";
    default: return nullptr;
  }
}

AVPixelFormat choose_hardware_format(AVCodecContext *context,
                                     const AVPixelFormat *formats) {
  const auto *selection =
      static_cast<HardwareFormatSelection *>(context->opaque);
  for (const AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE;
       ++format) {
    if (*format == selection->preferred) return *format;
  }
  // A device may initialize successfully yet reject a particular stream
  // profile at the first frame (for example AV1 on software Mesa VAAPI).
  // FFmpeg calls get_format again with the remaining software formats.
  if (selection->allow_software_fallback) {
    for (const AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE;
         ++format) {
      const AVPixFmtDescriptor *description = av_pix_fmt_desc_get(*format);
      if (description && !(description->flags & AV_PIX_FMT_FLAG_HWACCEL))
        return *format;
    }
  }
  return AV_PIX_FMT_NONE;
}

AVPixelFormat choose_software_format(AVCodecContext *,
                                     const AVPixelFormat *formats) {
  for (const AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE;
       ++format) {
    const AVPixFmtDescriptor *description = av_pix_fmt_desc_get(*format);
    if (description && !(description->flags & AV_PIX_FMT_FLAG_HWACCEL))
      return *format;
  }
  return AV_PIX_FMT_NONE;
}

Decoder make_decoder(AVFormatContext *format, int index,
                     RillightCoreHardware preference = RILLIGHT_CORE_HW_NONE,
                     bool allow_software_fallback = true,
                     const std::shared_ptr<void>& android_window = {},
                     uint32_t android_dovi_profiles = 0,
                     int64_t discard_before_us = -1) {
  Decoder result;
  if (index < 0 || index >= static_cast<int>(format->nb_streams)) return result;
  const auto *parameters = format->streams[index]->codecpar;
  bool native_dovi = false;
  bool export_dovi = false;
  if (preference == RILLIGHT_CORE_HW_MEDIACODEC &&
      parameters->codec_id == AV_CODEC_ID_HEVC) {
    const auto* side = av_packet_side_data_get(parameters->coded_side_data,
        parameters->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
    const bool declared_dovi = parameters->codec_tag == MKTAG('d','v','h','1') ||
        parameters->codec_tag == MKTAG('d','v','h','e');
    const AVCodec* platform = avcodec_find_decoder_by_name("hevc_mediacodec");
    const AVClass* options = platform ? platform->priv_class : nullptr;
    const bool dolby_surface = android_dovi_profiles && android_window && options &&
        av_opt_find(&options, "codec_mime", nullptr, 0, AV_OPT_SEARCH_FAKE_OBJ);
    const bool dovi_buffers = options && av_opt_find(
        &options, "export_dovi", nullptr, 0, AV_OPT_SEARCH_FAKE_OBJ);
    if (declared_dovi && (!side || side->size < sizeof(AVDOVIDecoderConfigurationRecord))) {
      // Without the recovered profile, neither a Dolby MIME nor ordinary
      // HEVC output establishes the correct color interpretation.
      if (!allow_software_fallback) {
        result.error = RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI;
        return result;
      }
      preference = RILLIGHT_CORE_HW_NONE;
    } else if (side && side->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
      const auto* record = reinterpret_cast<const AVDOVIDecoderConfigurationRecord*>(side->data);
      const bool supports_profile = android_dovi_profile_supported(
          record->dv_profile, android_dovi_profiles);
      // Profile 5 has no ordinary HDR10 base. Prefer a supported native Dolby
      // Surface; otherwise retain HEVC decoding with timestamp-matched RPU
      // and high precision P010 buffers for our color pipeline.
      if (record->dv_profile == 5) {
        if (dolby_surface && supports_profile) native_dovi = true;
        else if (dovi_buffers) export_dovi = true;
        else if (!allow_software_fallback) {
          result.error = RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI;
          return result;
        }
        if (!native_dovi && !export_dovi) preference = RILLIGHT_CORE_HW_NONE;
      } else if (dolby_surface && supports_profile) {
        native_dovi = true;
      }
    }
  }
  // FFmpeg's native AV1 decoder handles hardware surfaces only. A software
  // request must select the separately bundled dav1d decoder explicitly.
  const AVCodec *codec = preference == RILLIGHT_CORE_HW_NONE &&
                                 parameters->codec_id == AV_CODEC_ID_AV1
      ? avcodec_find_decoder_by_name("libdav1d")
      : avcodec_find_decoder(parameters->codec_id);
  if (preference == RILLIGHT_CORE_HW_MEDIACODEC &&
      parameters->codec_type == AVMEDIA_TYPE_VIDEO) {
    const char *name = mediacodec_decoder_name(parameters->codec_id);
    const AVCodec *platform = name ? avcodec_find_decoder_by_name(name) : nullptr;
    if (platform) codec = platform;
  }
  if (!codec) { result.error = AVERROR_DECODER_NOT_FOUND; return result; }
  AVCodecContext *context = avcodec_alloc_context3(codec);
  if (!context) { result.error = AVERROR(ENOMEM); return result; }
  if (avcodec_parameters_to_context(context, parameters) < 0) {
    avcodec_free_context(&context);
    result.error = AVERROR(EINVAL);
    return result;
  }
  // Audio decoders also need this to preserve timestamps when removing
  // priming samples. Without it the audio clock can remain unavailable.
  context->pkt_timebase = format->streams[index]->time_base;
  if (preference == RILLIGHT_CORE_HW_NONE &&
      parameters->codec_type == AVMEDIA_TYPE_VIDEO)
    context->get_format = choose_software_format;
  if (preference != RILLIGHT_CORE_HW_NONE &&
      parameters->codec_type == AVMEDIA_TYPE_VIDEO) {
    const AVHWDeviceType device_type = hardware_device_type(preference);
    const AVCodecHWConfig *selected = nullptr;
    for (int config_index = 0;; ++config_index) {
      const AVCodecHWConfig *config = avcodec_get_hw_config(codec, config_index);
      if (!config) break;
      if (config->device_type == device_type &&
          (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) {
        selected = config;
        break;
      }
    }
    int device_error = AVERROR(ENOSYS);
    if (selected) {
      AVBufferRef *device = nullptr;
#if defined(__ANDROID__)
      if (preference == RILLIGHT_CORE_HW_MEDIACODEC && android_window && !export_dovi) {
        device = av_hwdevice_ctx_alloc(device_type);
        if (device) {
          auto* device_context = reinterpret_cast<AVHWDeviceContext*>(device->data);
          auto* mc = static_cast<AVMediaCodecDeviceContext*>(device_context->hwctx);
          mc->native_window = android_window.get();
          device_context->user_opaque = new std::shared_ptr<void>(android_window);
          device_context->free = [](AVHWDeviceContext* context) {
            delete static_cast<std::shared_ptr<void>*>(context->user_opaque);
          };
          device_error = av_hwdevice_ctx_init(device);
          if (device_error < 0) av_buffer_unref(&device);
        } else device_error = AVERROR(ENOMEM);
      } else
#endif
      device_error = av_hwdevice_ctx_create(&device, device_type, nullptr,
                                             nullptr, 0);
      if (device_error >= 0) {
        context->hw_device_ctx = device;
        result.hw_format = std::make_shared<HardwareFormatSelection>(
            HardwareFormatSelection{selected->pix_fmt,
                                    allow_software_fallback});
        context->opaque = result.hw_format.get();
        context->get_format = choose_hardware_format;
        result.hardware = preference;
      }
    }
    if (device_error < 0) {
      avcodec_free_context(&context);
      if (allow_software_fallback)
        return make_decoder(format, index, RILLIGHT_CORE_HW_NONE, true);
      result.error = device_error;
      return result;
    }
  }
  if (preference == RILLIGHT_CORE_HW_MEDIACODEC) {
    // Stay in native buffers even on hosts which installed a Java VM.
    av_opt_set_int(context->priv_data, "ndk_codec", 1, 0);
    av_opt_set_int(context->priv_data, "delay_flush", 1, 0);
    if (export_dovi) {
      const int configured = av_opt_set_int(context->priv_data, "export_dovi", 1, 0);
      if (configured < 0) {
        avcodec_free_context(&context);
        result.error = configured;
        return result;
      }
      if (discard_before_us >= 0)
        av_opt_set_int(context->priv_data, "discard_before", discard_before_us, 0);
    }
    if (native_dovi) {
      const int configured = av_opt_set(context->priv_data, "codec_mime", "video/dolby-vision", 0);
      if (configured < 0) {
        avcodec_free_context(&context);
        result.error = configured;
        return result;
      }
      const auto* side = av_packet_side_data_get(parameters->coded_side_data,
          parameters->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
      if (side && side->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
        const int profile = reinterpret_cast<const AVDOVIDecoderConfigurationRecord*>(side->data)->dv_profile;
        if (profile >= 0 && profile <= 9)
          av_opt_set_int(context->priv_data, "dolby_profile", 1 << profile, 0);
      }
    }
  }
  const int open_result = avcodec_open2(context, codec, nullptr);
  if (open_result < 0) {
    avcodec_free_context(&context);
    if (preference != RILLIGHT_CORE_HW_NONE && allow_software_fallback)
      return make_decoder(format, index, RILLIGHT_CORE_HW_NONE, true);
    result.error = open_result;
    return result;
  }
  result.context = context;
  result.stream = index;
  result.android_color_buffers = export_dovi;
  return result;
}

int restore_dovi_configuration(AVFormatContext* format, int index,
                               PendingPackets* pending) {
  if (index < 0) return 0;
  auto* parameters = format->streams[index]->codecpar;
  const auto* existing = av_packet_side_data_get(parameters->coded_side_data,
      parameters->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
  if (parameters->codec_id != AV_CODEC_ID_HEVC || existing ||
      (parameters->codec_tag != MKTAG('d','v','h','1') &&
       parameters->codec_tag != MKTAG('d','v','h','e'))) return 0;
  // A remux may lose dvcC/dvvC. Decode one bounded prefix with FFmpeg to read
  // the actual RPU header, preserving every demuxed packet for normal playback.
  Decoder probe = make_decoder(format, index);
  if (!probe.context) return probe.error;
  AVPacket* packet = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  int profile = 0, result = 0;
  size_t bytes = 0;
  for (int i = 0; packet && frame && i < 2048 && bytes < 16u * 1024u * 1024u; ++i) {
    result = av_read_frame(format, packet);
    if (result < 0) break;
    auto* saved = av_packet_clone(packet);
    if (!saved) { result = AVERROR(ENOMEM); break; }
    pending->values.push_back(saved);
    bytes += static_cast<size_t>(std::max(packet->size, 0));
    if (packet->stream_index == index) {
      result = avcodec_send_packet(probe.context, packet);
      if (result >= 0) {
        while ((result = avcodec_receive_frame(probe.context, frame)) >= 0) {
          profile = dovi_profile_from_frame(frame);
          av_frame_unref(frame);
          if (profile) break;
        }
      }
    }
    av_packet_unref(packet);
    // A cut/remux can start before the first complete VPS/SPS/PPS. Continue
    // within the byte bound until a decodable keyframe supplies the real RPU.
    if (profile || (result < 0 && result != AVERROR(EAGAIN) &&
                    result != AVERROR_INVALIDDATA)) break;
  }
  av_frame_free(&frame);
  av_packet_free(&packet);
  avcodec_free_context(&probe.context);
  if (!profile) return result == AVERROR(ENOMEM) ? result : RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI;
  auto* side = av_packet_side_data_new(&parameters->coded_side_data,
      &parameters->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF,
      sizeof(AVDOVIDecoderConfigurationRecord), 0);
  if (!side) return AVERROR(ENOMEM);
  auto* record = reinterpret_cast<AVDOVIDecoderConfigurationRecord*>(side->data);
  *record = {};
  record->dv_version_major = 1;
  record->dv_profile = static_cast<uint8_t>(profile);
  record->rpu_present_flag = 1;
  record->bl_present_flag = 1;
  record->el_present_flag = profile == 4 || profile == 7;
  record->dv_bl_signal_compatibility_id = profile == 8 ?
      (parameters->color_trc == AVCOL_TRC_ARIB_STD_B67 ? 4 :
       parameters->color_trc == AVCOL_TRC_SMPTE2084 ? 1 : 6) : 0;
  if (profile == 5) {
    parameters->color_primaries = AVCOL_PRI_BT2020;
    parameters->color_trc = AVCOL_TRC_SMPTE2084;
  }
  return 0;
}

bool bitmap_subtitle_codec(AVCodecID codec) {
  return codec == AV_CODEC_ID_HDMV_PGS_SUBTITLE ||
         codec == AV_CODEC_ID_DVB_SUBTITLE ||
         codec == AV_CODEC_ID_DVD_SUBTITLE || codec == AV_CODEC_ID_XSUB;
}

#if RILLIGHT_HAVE_LIBASS
bool text_subtitle_codec(AVCodecID codec) {
  return codec == AV_CODEC_ID_SUBRIP || codec == AV_CODEC_ID_WEBVTT ||
         codec == AV_CODEC_ID_MOV_TEXT;
}
#endif

void copy_field(char *destination, size_t capacity, const char *source) {
  if (!source) return;
  std::snprintf(destination, capacity, "%s", source);
}

uint32_t hardware_capabilities(AVCodecID codec_id) {
  uint32_t capabilities = 0;
  auto collect = [&capabilities](const AVCodec *decoder) {
    if (!decoder) return;
    for (int index = 0;; ++index) {
      const AVCodecHWConfig *config = avcodec_get_hw_config(decoder, index);
      if (!config) break;
      if (!(config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) continue;
      switch (config->device_type) {
        case AV_HWDEVICE_TYPE_D3D11VA:
          capabilities |= RILLIGHT_CORE_HW_D3D11;
          break;
        case AV_HWDEVICE_TYPE_VIDEOTOOLBOX:
          capabilities |= RILLIGHT_CORE_HW_VIDEOTOOLBOX;
          break;
        case AV_HWDEVICE_TYPE_VAAPI:
          capabilities |= RILLIGHT_CORE_HW_VAAPI;
          break;
        case AV_HWDEVICE_TYPE_MEDIACODEC:
          capabilities |= RILLIGHT_CORE_HW_MEDIACODEC;
          break;
        default:
          break;
      }
    }
  };
  collect(avcodec_find_decoder(codec_id));
  const char *name = mediacodec_decoder_name(codec_id);
  if (name) collect(avcodec_find_decoder_by_name(name));
  return capabilities;
}

RillightCoreTrack make_track(const AVStream *stream) {
  RillightCoreTrack track{};
  track.struct_size = sizeof(track);
  track.stream_index = stream->index;
  track.codec_id = static_cast<int>(stream->codecpar->codec_id);
  copy_field(track.codec_name, sizeof(track.codec_name),
             avcodec_get_name(stream->codecpar->codec_id));
  const AVDictionaryEntry *language = av_dict_get(stream->metadata,
                                                  "language", nullptr, 0);
  const AVDictionaryEntry *title = av_dict_get(stream->metadata,
                                               "title", nullptr, 0);
  copy_field(track.language, sizeof(track.language),
             language ? language->value : nullptr);
  copy_field(track.title, sizeof(track.title), title ? title->value : nullptr);
  track.is_default = (stream->disposition & AV_DISPOSITION_DEFAULT) != 0;
  switch (stream->codecpar->codec_type) {
    case AVMEDIA_TYPE_VIDEO:
      track.type = RILLIGHT_CORE_TRACK_VIDEO;
      track.width = stream->codecpar->width;
      track.height = stream->codecpar->height;
      track.decoder_hardware_capabilities =
          hardware_capabilities(stream->codecpar->codec_id);
      break;
    case AVMEDIA_TYPE_AUDIO:
      track.type = RILLIGHT_CORE_TRACK_AUDIO;
      track.sample_rate = stream->codecpar->sample_rate;
      track.channels = stream->codecpar->ch_layout.nb_channels;
      break;
    case AVMEDIA_TYPE_SUBTITLE:
      track.type = RILLIGHT_CORE_TRACK_SUBTITLE;
      break;
    default:
      break;
  }
  return track;
}

int64_t frame_time(const AVFrame *frame, const AVStream *stream) {
  if (frame->best_effort_timestamp == AV_NOPTS_VALUE) return -1;
  return av_rescale_q(frame->best_effort_timestamp, stream->time_base,
                      AVRational{1, 1000000});
}

RillightCoreFrame *convert_video(const AVFrame *frame, int64_t pts,
                                 uint64_t session, uint64_t timeline,
                                 const AVStream *stream,
                                 VideoScale *scale, int output_width,
                                 int output_height, bool gpu_video = false,
                                 bool hdr_video = false,
                                 bool macos_edr = false) {
  if (frame->width <= 0 || frame->height <= 0 ||
      frame->width > static_cast<int>(kMaxVideoBytes / 4))
    return nullptr;
  const AVPacketSideData *dovi = av_packet_side_data_get(
      stream->codecpar->coded_side_data, stream->codecpar->nb_coded_side_data,
      AV_PKT_DATA_DOVI_CONF);
  bool requires_dovi = (stream->codecpar->codec_tag == MKTAG('d','v','h','1') ||
      stream->codecpar->codec_tag == MKTAG('d','v','h','e')) &&
      (!dovi || dovi->size < sizeof(AVDOVIDecoderConfigurationRecord));
  if (dovi && dovi->data && dovi->size >= 8) {
    const auto *record =
        reinterpret_cast<const AVDOVIDecoderConfigurationRecord *>(dovi->data);
    if (rillight_dovi_base_rejected(record->dv_profile,
                                    record->dv_bl_signal_compatibility_id)) {
      requires_dovi = true;
      if (record->dv_profile != 5 || record->el_present_flag) return nullptr;
    }
  }
  AVRational sar = frame->sample_aspect_ratio;
  if (sar.num <= 0 || sar.den <= 0) sar = stream->sample_aspect_ratio;
  if (sar.num <= 0 || sar.den <= 0)
    sar = stream->codecpar->sample_aspect_ratio;
  if (sar.num <= 0 || sar.den <= 0) sar = AVRational{1, 1};
  int width = frame->width;
  int height = frame->height;
  if (output_width > 0 && output_height > 0) {
    const auto* matrix = av_frame_get_side_data(frame, AV_FRAME_DATA_DISPLAYMATRIX);
    const auto* stream_matrix = av_packet_side_data_get(
        stream->codecpar->coded_side_data, stream->codecpar->nb_coded_side_data,
        AV_PKT_DATA_DISPLAYMATRIX);
    const int32_t* rotation = matrix && matrix->size >= 9 * sizeof(int32_t)
        ? reinterpret_cast<const int32_t*>(matrix->data)
        : stream_matrix && stream_matrix->size >= 9 * sizeof(int32_t)
        ? reinterpret_cast<const int32_t*>(stream_matrix->data) : nullptr;
    if (rotation && std::abs(static_cast<int64_t>(rotation[1])) >
                        std::abs(static_cast<int64_t>(rotation[0])))
      std::swap(output_width, output_height);
    const double factor = std::min({1.0,
        output_width / (frame->width * av_q2d(sar)),
        static_cast<double>(output_height) / frame->height});
    width = std::max(1, static_cast<int>(std::lround(frame->width * factor)));
    height = std::max(1, static_cast<int>(std::lround(frame->height * factor)));
    sar = av_mul_q(sar, av_div_q(AVRational{frame->width, frame->height},
                                AVRational{width, height}));
  }
  const int stride = width * 4;
  const int bytes = av_image_get_buffer_size(AV_PIX_FMT_RGBA, width, height, 1);
  if (bytes <= 0 || static_cast<size_t>(bytes) > kMaxVideoBytes) return nullptr;
  const AVColorRange source_range =
      frame->color_range != AVCOL_RANGE_UNSPECIFIED ? frame->color_range :
      stream->codecpar->color_range;
  const AVColorSpace source_space =
      frame->colorspace != AVCOL_SPC_UNSPECIFIED ? frame->colorspace :
      stream->codecpar->color_space;
  auto *output = new (std::nothrow) VideoOutputFrame{};
  if (!output) return nullptr;
  output->buffers = scale->buffers;
  // Borrow the planes synchronously. HDR/DV conversion keeps high precision
  // until the output-sized GPU surface is mapped to the public RGBA buffer.
  AVFrame source = *frame;
  source.color_range = source_range == AVCOL_RANGE_JPEG
                           ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG;
  source.colorspace = source_space == AVCOL_SPC_BT709 ||
                              source_space == AVCOL_SPC_BT2020_NCL
                          ? source_space : AVCOL_SPC_SMPTE170M;
  const int transfer = frame->color_trc != AVCOL_TRC_UNSPECIFIED
                           ? frame->color_trc
                           : stream->codecpar->color_trc;
  bool converted = false;
  bool linear_half = false;
  source.color_trc = static_cast<AVColorTransferCharacteristic>(transfer);
  if (source.color_primaries == AVCOL_PRI_UNSPECIFIED)
    source.color_primaries = stream->codecpar->color_primaries;
  const bool has_dovi = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA) != nullptr;
  if (requires_dovi || has_dovi || transfer == AVCOL_TRC_SMPTE2084 ||
      transfer == AVCOL_TRC_ARIB_STD_B67) {
    const auto render_color = [&](bool use_dovi) {
#if defined(_WIN32)
      if (scale->color_pipeline.Render(&source, width, height,
              use_dovi, output->data, stride)) return true;
#endif
      return source.format != AV_PIX_FMT_D3D11 &&
          scale->portable_color_pipeline.Render(&source, width, height,
              use_dovi, output->data, stride);
    };
#if defined(_WIN32)
    if (gpu_video) {
      const auto render_texture = [&](bool use_dovi) {
        return hdr_video ? scale->color_pipeline.RenderScRgbTexture(&source, width, height, use_dovi) :
            scale->color_pipeline.RenderTexture(&source, width, height, use_dovi);
      };
      void* texture = render_texture(requires_dovi || has_dovi);
      if (!texture && has_dovi && !requires_dovi)
        texture = render_texture(false);
      if (texture) {
        output->gpu_texture = std::shared_ptr<void>(texture, [](void* pointer) {
          static_cast<ID3D11Texture2D*>(pointer)->Release();
        });
        converted = true;
      }
    }
#else
    (void)gpu_video;
    (void)hdr_video;
#endif
    if (!converted && macos_edr) {
      const int half_stride = width * 8;
      const int half_bytes = half_stride * height;
      if (half_bytes > 0 && static_cast<size_t>(half_bytes) <= kMaxVideoBytes) {
        output->data = output->buffers->Acquire(half_bytes);
        if (!output->data) { delete output; return nullptr; }
        const auto render_half = [&](bool use_dovi) {
          return scale->portable_color_pipeline.RenderLinearHalf(
              &source, width, height, use_dovi,
              reinterpret_cast<uint16_t*>(output->data), half_stride);
        };
        converted = render_half(requires_dovi || has_dovi);
        if (!converted && has_dovi && !requires_dovi) converted = render_half(false);
        linear_half = converted;
        if (!converted) {
          output->buffers->Recycle(output->data, half_bytes);
          output->data = nullptr;
        }
      }
    }
    if (!converted) {
      output->data = output->buffers->Acquire(bytes);
      if (!output->data) { delete output; return nullptr; }
      converted = render_color(requires_dovi || has_dovi);
    }
    // A compatible HDR10/HLG base remains valid if an enhancement-layer RPU
    // cannot be composed. Preserve its precision instead of quantizing before
    // tone mapping. Profile 5 must never take this base-layer fallback.
    if (!converted && has_dovi && !requires_dovi) converted = render_color(false);
  }
  if (requires_dovi && !converted) {
    output->buffers->Recycle(output->data, bytes);
    delete output;
    return nullptr;
  }
  if (!converted) {
    if (!output->data) output->data = output->buffers->Acquire(bytes);
    if (!output->data) { delete output; return nullptr; }
    if (!scale->context) {
      scale->context = sws_alloc_context();
      if (!scale->context) {
        output->buffers->Recycle(output->data, bytes);
        delete output;
        return nullptr;
      }
      scale->context->threads = 4;
      scale->context->flags = SWS_BILINEAR;
      scale->context->backends = SWS_BACKEND_LEGACY;
    }
  AVFrame destination{};
  destination.width = width;
  destination.height = height;
  destination.format = AV_PIX_FMT_RGBA;
  destination.data[0] = output->data;
  destination.linesize[0] = stride;
  destination.color_range = AVCOL_RANGE_JPEG;
  destination.colorspace = AVCOL_SPC_RGB;
  destination.color_primaries = source.color_primaries;
  destination.color_trc = source.color_trc;
  destination.flags = source.flags;
  if (sws_scale_frame(scale->context, &destination, &source) < 0) {
    output->buffers->Recycle(output->data, bytes);
    delete output;
    return nullptr;
  }
  tonemap_rgba(output->data, stride, width, height, transfer);
  }
  output->struct_size = sizeof(RillightCoreFrame);
  output->type = output->gpu_texture ? RILLIGHT_CORE_VIDEO_D3D11 :
      linear_half ? RILLIGHT_CORE_VIDEO_RGBA16F : RILLIGHT_CORE_VIDEO_RGBA;
  output->session_id = session;
  output->timeline_version = timeline;
  output->pts_us = pts;
  output->width = width;
  output->height = height;
  output->stride = linear_half ? width * 8 :
      output->gpu_texture && hdr_video ? stride * 2 : stride;
  output->data_size = linear_half ? width * height * 8 :
      output->gpu_texture && hdr_video ? bytes * 2 : bytes;
  output->sar_num = sar.num;
  output->sar_den = sar.den;
  output->source_color_range = source_range;
  output->source_color_space = source_space;
  output->source_color_primaries =
      frame->color_primaries != AVCOL_PRI_UNSPECIFIED ?
      frame->color_primaries : stream->codecpar->color_primaries;
  output->source_color_transfer =
      frame->color_trc != AVCOL_TRC_UNSPECIFIED ?
      frame->color_trc : stream->codecpar->color_trc;
  const AVFrameSideData *matrix =
      av_frame_get_side_data(frame, AV_FRAME_DATA_DISPLAYMATRIX);
  if (matrix && matrix->size >= sizeof(output->display_matrix)) {
    std::memcpy(output->display_matrix, matrix->data,
                sizeof(output->display_matrix));
    output->has_display_matrix = 1;
  } else {
    const AVPacketSideData *stream_matrix = av_packet_side_data_get(
        stream->codecpar->coded_side_data,
        stream->codecpar->nb_coded_side_data,
        AV_PKT_DATA_DISPLAYMATRIX);
    if (stream_matrix &&
        stream_matrix->size >= sizeof(output->display_matrix)) {
      std::memcpy(output->display_matrix, stream_matrix->data,
                  sizeof(output->display_matrix));
      output->has_display_matrix = 1;
    }
  }
  return output;
}

int prepare_audio_filter(AudioFilter *filter, const AVFrame *frame,
                         double speed, int64_t media_pts) {
  if (filter->graph && filter->input_rate == frame->sample_rate &&
      filter->input_format == frame->format && filter->speed == speed &&
      av_channel_layout_compare(&filter->input_layout, &frame->ch_layout) == 0)
    return 0;
  close_audio_filter(filter);
  if (frame->sample_rate <= 0 || frame->ch_layout.nb_channels <= 0)
    return AVERROR(EINVAL);
  filter->graph = avfilter_graph_alloc();
  if (!filter->graph) return AVERROR(ENOMEM);
  char layout[128] = {};
  if (av_channel_layout_describe(&frame->ch_layout, layout,
                                 sizeof(layout)) < 0)
    return AVERROR(EINVAL);
  char args[512] = {};
  std::snprintf(args, sizeof(args),
                "time_base=1/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
                frame->sample_rate, frame->sample_rate,
                av_get_sample_fmt_name(static_cast<AVSampleFormat>(frame->format)),
                layout);
  AVFilterContext *tempo = nullptr;
  AVFilterContext *tempo_second = nullptr;
  AVFilterContext *format = nullptr;
  int result = avfilter_graph_create_filter(
      &filter->source, avfilter_get_by_name("abuffer"), "input", args,
      nullptr, filter->graph);
  if (result < 0) return result;
  if (speed != 1.0) {
    // Unity playback needs format conversion/downmix only. Running WSOLA at
    // unity adds a priming window and packet buffering to every open/seek,
    // including E-AC-3/TrueHD, without changing the requested playback speed.
    const std::string tempo_arg = std::to_string(std::min(speed, 2.0));
    result = avfilter_graph_create_filter(
        &tempo, avfilter_get_by_name("atempo"), "tempo", tempo_arg.c_str(),
        nullptr, filter->graph);
    if (result < 0) return result;
  }
  if (speed > 2.0) {
    const std::string second_arg = std::to_string(speed / 2.0);
    result = avfilter_graph_create_filter(
        &tempo_second, avfilter_get_by_name("atempo"), "tempo_second",
        second_arg.c_str(), nullptr, filter->graph);
    if (result < 0) return result;
  }
  result = avfilter_graph_create_filter(
      &format, avfilter_get_by_name("aformat"), "format",
      "sample_fmts=s16:sample_rates=48000:channel_layouts=stereo",
      nullptr, filter->graph);
  if (result < 0) return result;
  result = avfilter_graph_create_filter(
      &filter->sink, avfilter_get_by_name("abuffersink"), "output", nullptr,
      nullptr, filter->graph);
  if (result < 0) return result;
  if (tempo) {
    result = avfilter_link(filter->source, 0, tempo, 0);
    if (result < 0) return result;
  }
  if (tempo_second) {
    result = avfilter_link(tempo, 0, tempo_second, 0);
    if (result < 0) return result;
  }
  result = avfilter_link(tempo_second ? tempo_second :
                        tempo ? tempo : filter->source, 0, format, 0);
  if (result < 0) return result;
  result = avfilter_link(format, 0, filter->sink, 0);
  if (result < 0) return result;
  result = avfilter_graph_config(filter->graph, nullptr);
  if (result < 0) return result;
  result = av_channel_layout_copy(&filter->input_layout, &frame->ch_layout);
  if (result < 0) return result;
  filter->input_rate = frame->sample_rate;
  filter->input_format = static_cast<AVSampleFormat>(frame->format);
  filter->speed = speed;
  filter->media_anchor = media_pts;
  filter->output_anchor = AV_NOPTS_VALUE;
  filter->next_media_pts = media_pts;
  return 0;
}

RillightCoreFrame *convert_audio(const AVFrame *frame, AudioFilter *filter,
                                 uint64_t session, uint64_t timeline) {
  if (frame->format != AV_SAMPLE_FMT_S16 || frame->sample_rate != 48000 ||
      frame->ch_layout.nb_channels != 2 || frame->nb_samples <= 0 ||
      frame->nb_samples > 480000) return nullptr;
  const int bytes = frame->nb_samples * 4;
  auto *output = new (std::nothrow) RillightCoreFrame{};
  if (!output) return nullptr;
  output->data = new (std::nothrow) uint8_t[bytes];
  if (!output->data) {
    delete output;
    return nullptr;
  }
  std::memcpy(output->data, frame->data[0], bytes);
  int64_t pts = filter->next_media_pts;
  if (frame->pts != AV_NOPTS_VALUE && filter->media_anchor != AV_NOPTS_VALUE) {
    const int64_t output_pts = av_rescale_q(
        frame->pts, av_buffersink_get_time_base(filter->sink),
        AVRational{1, 1000000});
    if (filter->output_anchor == AV_NOPTS_VALUE) filter->output_anchor = output_pts;
    pts = filter->media_anchor + static_cast<int64_t>(
                                     (output_pts - filter->output_anchor) *
                                     filter->speed);
  }
  filter->next_media_pts = pts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE :
      pts + static_cast<int64_t>(frame->nb_samples * 1000000.0 /
                                 48000.0 * filter->speed);
  output->struct_size = sizeof(*output);
  output->type = RILLIGHT_CORE_AUDIO_S16;
  output->session_id = session;
  output->timeline_version = timeline;
  output->pts_us = pts == AV_NOPTS_VALUE ? -1 : pts;
  output->sample_rate = 48000;
  output->channels = 2;
  output->sample_count = frame->nb_samples;
  output->data_size = bytes;
  return output;
}

int enqueue(RillightCoreImpl *core, RillightCoreFrame *frame,
             int video_index, uint64_t timeline) {
  if (!frame) return 0;
  std::unique_lock lock(core->mutex);
  auto &queue = frame->type != RILLIGHT_CORE_AUDIO_S16 ? core->video : core->audio;
  auto &bytes = frame->type != RILLIGHT_CORE_AUDIO_S16 ? core->video_bytes : core->audio_bytes;
  if ((core->state == RILLIGHT_CORE_RECOVERING ||
       core->state == RILLIGHT_CORE_OPENING) && frame->pts_us != -1 &&
      frame->pts_us + (frame->type != RILLIGHT_CORE_AUDIO_S16 ? 5000 : 20000) <
          core->base_position) {
    lock.unlock();
    rillight_core_release_frame(frame);
    return 0;
  }
  const auto max_count = frame->type != RILLIGHT_CORE_AUDIO_S16
                             ? kMaxVideoFrames : kMaxAudioFrames;
  const auto max_bytes = frame->type != RILLIGHT_CORE_AUDIO_S16
                             ? kMaxVideoBytes * ((core->hdr_video || core->macos_edr) ? 2 : 1)
                             : kMaxAudioBytes;
  core->wake.wait(lock, [&] {
    return core->stop || core->decode_abort || core->timeline != timeline ||
           (queue.size() < max_count && bytes + frame->data_size <= max_bytes);
  });
  if (core->stop || core->decode_abort || core->timeline != timeline) {
    lock.unlock();
    rillight_core_release_frame(frame);
    return 0;
  }
  bytes += frame->data_size;
  queue.push_back(frame);
  if (frame->type != RILLIGHT_CORE_AUDIO_S16) core->first_video = true;
  if (frame->type == RILLIGHT_CORE_AUDIO_S16) core->first_audio = true;
  if ((video_index >= 0 && core->first_video) ||
      (video_index < 0 && core->first_audio)) {
    if (core->state == RILLIGHT_CORE_OPENING ||
        core->state == RILLIGHT_CORE_BUFFERING ||
        core->state == RILLIGHT_CORE_RECOVERING) {
      if (core->base_position == 0 && frame->pts_us > 0)
        core->base_position = frame->pts_us;
      core->base_time = Clock::now();
      core->state = core->play_intent ? RILLIGHT_CORE_PLAYING
                                      : RILLIGHT_CORE_PAUSED;
    }
  }
  core->wake.notify_all();
  return 0;
}

int drain_audio_filter(RillightCoreImpl *core, AudioFilter *filter,
                       int video_index, uint64_t session, uint64_t timeline) {
  if (!filter->graph) return 0;
  AVFrame *filtered = av_frame_alloc();
  if (!filtered) return AVERROR(ENOMEM);
  int result = 0;
  while (!core->stop) {
#if defined(__ANDROID__)
    // A TrueHD access unit can contain only 40 samples. Coalesce into 10 ms
    // PCM blocks so the bounded queue and JNI/AudioTrack feeder do not need
    // 1,200 handoffs per second. get_samples preserves a short final block at
    // EOF; seek/track changes discard the filter with the old timeline.
    result = av_buffersink_get_samples(filter->sink, filtered, 480);
#else
    result = av_buffersink_get_frame(filter->sink, filtered);
#endif
    if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
      result = 0;
      break;
    }
    if (result < 0) break;
    auto *output = convert_audio(filtered, filter, session, timeline);
    av_frame_unref(filtered);
    if (!output) {
      result = AVERROR(EINVAL);
      break;
    }
    result = enqueue(core, output, video_index, timeline);
    if (result < 0) break;
    std::lock_guard lock(core->mutex);
    if (core->timeline != timeline) break;
  }
  av_frame_free(&filtered);
  return result;
}

int convert_video_frame(RillightCoreImpl *core, AVFormatContext *format,
                        AVFrame *decoded, int stream_index, uint32_t hardware,
                        VideoScale *scale, std::vector<SubtitleCue> *cues,
                        AssRenderer *ass, uint64_t session, uint64_t timeline,
                        std::mutex *subtitle_mutex) {
  int result = 0;
  const int64_t pts = frame_time(decoded, format->streams[stream_index]);
  bool discard = false;
  int output_width;
  int output_height;
  bool gpu_video = false;
  bool hdr_video = false;
  bool macos_edr = false;
  {
    std::lock_guard lock(core->mutex);
    output_width = core->output_width;
    output_height = core->output_height;
    hdr_video = core->hdr_video;
    macos_edr = core->macos_edr;
    gpu_video = core->gpu_video && (core->subtitle_index < 0 || hdr_video);
    const int64_t clock = playback_position(core);
    discard = core->timeline != timeline ||
        (pts >= 0 &&
         (((core->state == RILLIGHT_CORE_RECOVERING ||
            core->state == RILLIGHT_CORE_OPENING) &&
           pts + 5000 < core->base_position) ||
          (core->state == RILLIGHT_CORE_PLAYING && core->first_video &&
           pts + 100000 < clock)));
  }
  if (discard) {
    // Decode reference frames, but skip GPU readback, RGBA conversion and
    // subtitle composition for output that is already late. Doing all that
    // work before the renderer drops it delays subsequent useful pictures.
    return 0;
  }
  const AVFrame *picture = decoded;
  bool decoded_with_hardware = false;
  RillightCoreFrame *output = nullptr;
#if defined(__ANDROID__)
  const bool android_color = hardware == RILLIGHT_CORE_HW_MEDIACODEC &&
      decoded->format == AV_PIX_FMT_P010LE &&
      av_frame_get_side_data(decoded, AV_FRAME_DATA_DOVI_METADATA);
  if (android_color || (hardware == RILLIGHT_CORE_HW_MEDIACODEC &&
      decoded->format == AV_PIX_FMT_MEDIACODEC && decoded->data[3])) {
    auto* native = new (std::nothrow) VideoOutputFrame{};
    AVFrame* retained = av_frame_clone(decoded);
    if (!native || !retained) {
      delete native;
      av_frame_free(&retained);
      return AVERROR(ENOMEM);
    }
    native->codec_frame = std::shared_ptr<AVFrame>(retained,
        [](AVFrame* frame) { av_frame_free(&frame); });
    native->struct_size = sizeof(RillightCoreFrame);
    native->type = android_color ? RILLIGHT_CORE_VIDEO_ANDROID_P010 : RILLIGHT_CORE_VIDEO_MEDIACODEC;
    native->session_id = session;
    native->timeline_version = timeline;
    native->pts_us = pts;
    native->width = decoded->width;
    native->height = decoded->height;
    native->sar_num = decoded->sample_aspect_ratio.num > 0 ? decoded->sample_aspect_ratio.num : 1;
    native->sar_den = decoded->sample_aspect_ratio.den > 0 ? decoded->sample_aspect_ratio.den : 1;
    const int64_t cost = video_frame_cost(decoded);
    if (cost <= 0 || cost > std::numeric_limits<int>::max()) {
      delete native;
      return AVERROR_INVALIDDATA;
    }
    native->data_size = static_cast<int>(cost);
    native->source_color_range = decoded->color_range;
    native->source_color_space = decoded->colorspace;
    native->source_color_primaries = decoded->color_primaries;
    native->source_color_transfer = decoded->color_trc;
    const auto* matrix = av_packet_side_data_get(
        format->streams[stream_index]->codecpar->coded_side_data,
        format->streams[stream_index]->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    if (matrix && matrix->size >= sizeof(native->display_matrix)) {
      std::memcpy(native->display_matrix, matrix->data, sizeof(native->display_matrix));
      native->has_display_matrix = 1;
    }
    output = native;
    decoded_with_hardware = true;
  }
#endif
#if defined(_WIN32)
  const auto* video_stream = format->streams[stream_index];
  const int transfer = decoded->color_trc == AVCOL_TRC_UNSPECIFIED
      ? video_stream->codecpar->color_trc : decoded->color_trc;
  const bool gpu_color = transfer == AVCOL_TRC_SMPTE2084 ||
      transfer == AVCOL_TRC_ARIB_STD_B67 ||
      av_frame_get_side_data(decoded, AV_FRAME_DATA_DOVI_METADATA) != nullptr;
  if (gpu_color && decoded->format == AV_PIX_FMT_D3D11 && decoded->hw_frames_ctx) {
    output = convert_video(decoded, pts, session, timeline,
        format->streams[stream_index], scale, output_width, output_height,
        gpu_video, hdr_video, macos_edr);
    decoded_with_hardware = output != nullptr;
  }
#endif
  // CPU planes alone do not identify the decoder backend. Our locked
  // MediaCodec wrapper carries its actual component name on byte output.
#if defined(__ANDROID__)
  if (hardware == RILLIGHT_CORE_HW_MEDIACODEC && av_dict_get(
      decoded->metadata, "rillight.mediacodec.name", nullptr, 0))
    decoded_with_hardware = true;
#endif
  if (!output && hardware != RILLIGHT_CORE_HW_NONE && decoded->hw_frames_ctx) {
    // Retain the CPU planes between downloads. Allocating/freeing a new
    // 4K staging frame on every transfer adds page faults to the video lane.
    // A different hardware frames context invalidates both size and format.
    if (!scale->download_context ||
        scale->download_context->data != decoded->hw_frames_ctx->data) {
      av_frame_free(&scale->downloaded);
      av_buffer_unref(&scale->download_context);
      scale->download_context = av_buffer_ref(decoded->hw_frames_ctx);
    }
    if (!scale->downloaded) scale->downloaded = av_frame_alloc();
    if (!scale->downloaded || !scale->download_context) {
      return AVERROR(ENOMEM);
    }
    result = av_hwframe_transfer_data(scale->downloaded, decoded, 0);
    // copy_props appends side data; clear the preceding frame's metadata
    // without releasing the reusable pixel allocation.
    av_frame_side_data_free(&scale->downloaded->side_data,
                            &scale->downloaded->nb_side_data);
    av_dict_free(&scale->downloaded->metadata);
    if (result >= 0)
      result = av_frame_copy_props(scale->downloaded, decoded);
    if (result < 0) return result;
    picture = scale->downloaded;
    decoded_with_hardware = true;
  }
  if (!output) output = convert_video(picture, pts, session, timeline,
                               format->streams[stream_index], scale,
                               output_width, output_height, gpu_video, hdr_video,
                               macos_edr);
  if (!output) return AVERROR(EINVAL);
  if (decoded_with_hardware) {
    std::lock_guard lock(core->mutex);
    for (auto &track : core->tracks) {
      if (track.stream_index == stream_index)
        track.actual_hardware = hardware;
    }
  }
  // Compose at presentation time: queued frames adopt the current policy,
  // and the retained clean frame can be rerendered while playback is paused.
  (void)cues; (void)ass; (void)subtitle_mutex;
  return enqueue(core, output, stream_index, timeline);
}

using VideoSink = std::function<int(AVFrame *, int, uint32_t, uint64_t)>;

int decode_packet(RillightCoreImpl *core, AVFormatContext *format,
                  Decoder &decoder, const AVPacket *packet, int video_index,
                  VideoScale *scale, AudioFilter *audio_filter,
                  std::vector<SubtitleCue> *cues, AssRenderer *ass,
                  double speed,
                  uint64_t session, uint64_t timeline, std::mutex *subtitle_mutex = nullptr,
                  const VideoSink *video_sink = nullptr) {
  if (!decoder.context) return 0;
  const auto recover_dts_packet = [&](int error) {
    return error == AVERROR_INVALIDDATA && packet && packet->size > 0 &&
        decoder.context->codec_id == AV_CODEC_ID_DTS &&
        decoder.dts_recovery.skipInvalidPacket();
  };
  const auto non_picture_error = [&](int error) {
    const auto* context = decoder.context;
    if (error != AVERROR_INVALIDDATA || !packet || packet->size <= 0 ||
        context->codec_id != AV_CODEC_ID_H264) return false;
    const int nal_length = context->extradata_size >= 5 && context->extradata[0] == 1
        ? (context->extradata[4] & 3) + 1 : 0;
    return rillight_h264_non_picture(packet->data,
                                    static_cast<size_t>(packet->size), nal_length);
  };
  int result = avcodec_send_packet(decoder.context, packet);
  if (recover_dts_packet(result)) return 0;
  if (non_picture_error(result)) return 0;
  bool submitted = result != AVERROR(EAGAIN);
  if (result < 0 && submitted) return result;
  AVFrame *decoded = av_frame_alloc();
  if (!decoded) return AVERROR(ENOMEM);
  while (!core->stop && !core->decode_abort) {
    result = avcodec_receive_frame(decoder.context, decoded);
    if (result == AVERROR(EAGAIN) && !submitted) {
      // Backpressure is not a failed hardware decoder. Retain the packet,
      // drain output, and retry rather than replacing MediaCodec in software.
      { std::lock_guard lock(core->mutex); if (core->timeline != timeline) break; }
      result = avcodec_send_packet(decoder.context, packet);
      if (recover_dts_packet(result)) { result = 0; break; }
      if (non_picture_error(result)) { result = 0; break; }
      submitted = result != AVERROR(EAGAIN);
      if (result < 0 && submitted) break;
      if (!submitted) std::this_thread::sleep_for(std::chrono::milliseconds(1));
      continue;
    }
    if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) break;
    if (recover_dts_packet(result)) { result = 0; break; }
    if (result < 0) break;
    decoder.dts_recovery.reset();
    const int64_t pts = frame_time(decoded, format->streams[decoder.stream]);
    if (decoder.stream == video_index) {
      result = video_sink
          ? (*video_sink)(decoded, decoder.stream, decoder.hardware, timeline)
          : convert_video_frame(core, format, decoded, decoder.stream,
                                decoder.hardware, scale, cues, ass,
                                session, timeline, subtitle_mutex);
      av_frame_unref(decoded);
      if (result < 0) break;
    } else {
      // Codec priming commonly gives the first audio frame a negative PTS.
      // Keep that valid anchor distinct from missing timestamps; otherwise
      // every filtered frame inherits "unknown" and seeking plays old audio
      // while the video clock runs ahead and discards all following pictures.
      const int64_t audio_pts = decoded->best_effort_timestamp == AV_NOPTS_VALUE
                                    ? AV_NOPTS_VALUE : pts;
      result = prepare_audio_filter(audio_filter, decoded, speed, audio_pts);
      decoded->pts = audio_pts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE :
          av_rescale_q(audio_pts, AVRational{1, 1000000},
                       AVRational{1, decoded->sample_rate});
      if (result >= 0)
        result = av_buffersrc_add_frame_flags(audio_filter->source, decoded,
                                               AV_BUFFERSRC_FLAG_KEEP_REF);
      av_frame_unref(decoded);
      if (result < 0) break;
      result = drain_audio_filter(core, audio_filter, video_index, session,
                                  timeline);
      if (result < 0) break;
    }
    std::lock_guard lock(core->mutex);
    if (core->timeline != timeline) break;
  }
  av_frame_free(&decoded);
  if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) return 0;
  return result < 0 ? result : 0;
}

// Compressed packets, not decoded pixels, separate demux I/O from each decoder.
// The core mutex protects queue/control state only; codecs and conversion never
// run under it. A timeline barrier retires in-flight work before codec mutation.
class DecodeLane {
 public:
  using Decode = std::function<int(const AVPacket *, uint64_t)>;
  DecodeLane(RillightCoreImpl *core, size_t budget, int type)
      : core_(core), budget_(budget), type_(type) {}
  ~DecodeLane() { Stop(); }
  bool Start(Decode decode) {
    decode_ = std::move(decode);
    try { thread_ = std::thread([this] { Run(); }); }
    catch (...) { return false; }
    return true;
  }
  int Push(const AVPacket *packet, uint64_t timeline) {
    size_t cost = sizeof(AVPacket);
    if (packet) {
      cost += std::max(0, packet->size);
      for (int i = 0; i < packet->side_data_elems; ++i)
        cost += packet->side_data[i].size;
    }
    if (cost > budget_) return AVERROR(ENOBUFS);
    std::unique_lock lock(core_->mutex);
    const auto video_has_work = [&] {
      return core_->video_packets_pending > 0 || core_->video_decode_busy;
    };
    if (type_ == RILLIGHT_CORE_AUDIO_S16 && core_->video_index >= 0 &&
        !core_->first_video && (bytes_ + cost > budget_ || queue_.size() >= 2048)) {
      // PCM is withheld until the first picture. If video is already queued
      // or decoding, let it finish even on cold open: the demux thread can fill
      // this queue before the video lane gets CPU time. With no video work,
      // cold open fails boundedly; seek recovery skips excess preroll instead
      // of waiting for audio space that cannot become available yet.
      if (!packet) return AVERROR(ENOBUFS);
      if (video_has_work()) {
        core_->wake.wait(lock, [&] {
          return stopped_ || core_->stop || core_->decode_abort ||
              core_->timeline != timeline || core_->first_video ||
              !video_has_work() ||
              (enabled_ && bytes_ + cost <= budget_ && queue_.size() < 2048);
        });
      }
      if (stopped_ || core_->stop || core_->decode_abort ||
          core_->timeline != timeline) return 0;
      if (!core_->first_video && !video_has_work() &&
          (bytes_ + cost > budget_ || queue_.size() >= 2048)) {
        return core_->state == RILLIGHT_CORE_RECOVERING ? 0 : AVERROR(ENOBUFS);
      }
    }
    core_->wake.wait(lock, [&] {
      return stopped_ || core_->stop || core_->decode_abort ||
          core_->timeline != timeline ||
          (enabled_ && bytes_ + cost <= budget_ && queue_.size() < 2048);
    });
    if (stopped_ || core_->stop || core_->decode_abort ||
        core_->timeline != timeline) return 0;
    auto *copy = packet ? av_packet_clone(packet) : nullptr;
    if (packet && !copy) return AVERROR(ENOMEM);
    if (type_ == RILLIGHT_CORE_VIDEO_RGBA && packet)
      core_->video_packets_pending++;
    queue_.push_back({copy, timeline, cost});
    bytes_ += cost;
    core_->wake.notify_all();
    return 0;
  }
  void Quiesce() {
    std::unique_lock lock(core_->mutex);
    enabled_ = false;
    Clear();
    core_->wake.notify_all();
    core_->wake.wait(lock, [&] { return !busy_; });
  }
  void Resume() {
    std::lock_guard lock(core_->mutex);
    enabled_ = true;
    core_->wake.notify_all();
  }
  void Drain(uint64_t timeline) {
    std::unique_lock lock(core_->mutex);
    core_->wake.wait(lock, [&] {
      return core_->stop || core_->decode_abort || core_->timeline != timeline ||
          (queue_.empty() && !busy_);
    });
  }
  void Stop() {
    {
      std::lock_guard lock(core_->mutex);
      stopped_ = true;
      Clear();
      core_->wake.notify_all();
    }
    if (thread_.joinable()) thread_.join();
  }
 private:
  struct Packet { AVPacket *value; uint64_t timeline; size_t cost; };
  void Clear() {
    for (auto &packet : queue_) av_packet_free(&packet.value);
    queue_.clear();
    bytes_ = 0;
    if (type_ == RILLIGHT_CORE_VIDEO_RGBA) core_->video_packets_pending = 0;
  }
  void Run() {
    for (;;) {
      Packet packet{};
      {
        std::unique_lock lock(core_->mutex);
        core_->wake.wait(lock, [&] {
          const bool preview_needed = type_ == RILLIGHT_CORE_VIDEO_RGBA
              ? !core_->first_video : type_ == RILLIGHT_CORE_AUDIO_S16
              ? !core_->first_audio : !core_->first_video;
          return stopped_ || core_->stop || core_->decode_abort ||
              (enabled_ && !queue_.empty() &&
               (queue_.front().timeline != core_->timeline ||
                core_->play_intent || preview_needed));
        });
        if (stopped_ || core_->stop || core_->decode_abort) break;
        packet = queue_.front();
        queue_.pop_front();
        bytes_ -= packet.cost;
        if (type_ == RILLIGHT_CORE_VIDEO_RGBA && packet.value &&
            core_->video_packets_pending > 0)
          core_->video_packets_pending--;
        core_->wake.notify_all();
        if (packet.timeline != core_->timeline) {
          av_packet_free(&packet.value);
          continue;
        }
        busy_ = true;
        if (type_ == RILLIGHT_CORE_VIDEO_RGBA) core_->video_decode_busy = true;
      }
      int result;
      try { result = decode_(packet.value, packet.timeline); }
      catch (...) { result = AVERROR_UNKNOWN; }
      av_packet_free(&packet.value);
      bool failed = false;
      {
        std::lock_guard lock(core_->mutex);
        busy_ = false;
        if (type_ == RILLIGHT_CORE_VIDEO_RGBA) core_->video_decode_busy = false;
        if (result < 0 && packet.timeline == core_->timeline && !core_->stop) {
          int expected = 0;
          core_->decode_error.compare_exchange_strong(expected, result);
          core_->decode_abort = true;
          failed = true;
        }
        core_->wake.notify_all();
      }
      if (failed) {
        core_->io.cancel_media_io(core_->io.opaque);
        break;
      }
    }
  }
  RillightCoreImpl *core_;
  const size_t budget_;
  const int type_;
  Decode decode_;
  std::thread thread_;
  std::deque<Packet> queue_;
  size_t bytes_ = 0;
  bool enabled_ = true, busy_ = false, stopped_ = false;
};

// Hardware receive submits work asynchronously. Keep a bounded decoded-frame
// lane so GPU download / colorspace conversion cannot stop the decoder from
// feeding the next pictures. Audio, subtitles and demux retain their own lanes.
class VideoConvertLane {
 public:
  using Convert = std::function<int(AVFrame *, int, uint32_t, uint64_t)>;
  explicit VideoConvertLane(RillightCoreImpl *core) : core_(core) {}
  ~VideoConvertLane() { Stop(); }
  bool Start(Convert convert) {
    convert_ = std::move(convert);
    try { thread_ = std::thread([this] { Run(); }); }
    catch (...) { return false; }
    return true;
  }
  int Push(AVFrame *frame, int stream, uint32_t hardware, uint64_t timeline) {
    // An opaque MediaCodec output is a retained decoder buffer, not a CPU
    // image. av_image_get_buffer_size rejects it and used to trigger software
    // fallback immediately after the first successful Surface frame.
    const int cost = video_frame_cost(frame);
    if (cost <= 0 || static_cast<size_t>(cost) > kMaxVideoBytes) return AVERROR(ENOBUFS);
    std::unique_lock lock(core_->mutex);
    core_->wake.wait(lock, [&] {
      return stopped_ || core_->stop || core_->decode_abort ||
          core_->timeline != timeline ||
          (enabled_ && queue_.size() < 3 && bytes_ + cost <= kMaxVideoBytes);
    });
    if (stopped_ || core_->stop || core_->decode_abort || core_->timeline != timeline) return 0;
    auto *copy = av_frame_clone(frame);
    if (!copy) return AVERROR(ENOMEM);
    queue_.push_back({copy, stream, hardware, timeline, static_cast<size_t>(cost)});
    bytes_ += cost;
    core_->wake.notify_all();
    return 0;
  }
  void Quiesce() {
    std::unique_lock lock(core_->mutex);
    enabled_ = false;
    Clear();
    core_->wake.notify_all();
    core_->wake.wait(lock, [&] { return !busy_; });
  }
  void Resume() {
    std::lock_guard lock(core_->mutex);
    enabled_ = true;
    core_->wake.notify_all();
  }
  void Drain(uint64_t timeline) {
    std::unique_lock lock(core_->mutex);
    core_->wake.wait(lock, [&] {
      return core_->stop || core_->decode_abort || core_->timeline != timeline ||
          (queue_.empty() && !busy_);
    });
  }
  void Stop() {
    {
      std::lock_guard lock(core_->mutex);
      stopped_ = true;
      Clear();
      core_->wake.notify_all();
    }
    if (thread_.joinable()) thread_.join();
  }
 private:
  struct Picture { AVFrame *frame; int stream; uint32_t hardware; uint64_t timeline; size_t cost; };
  void Clear() {
    for (auto &picture : queue_) av_frame_free(&picture.frame);
    queue_.clear();
    bytes_ = 0;
  }
  void Run() {
    for (;;) {
      Picture picture{};
      {
        std::unique_lock lock(core_->mutex);
        core_->wake.wait(lock, [&] {
          return stopped_ || core_->stop || core_->decode_abort ||
              (enabled_ && !queue_.empty() &&
               (queue_.front().timeline != core_->timeline ||
                core_->play_intent || !core_->first_video));
        });
        if (stopped_ || core_->stop || core_->decode_abort) break;
        picture = queue_.front();
        queue_.pop_front();
        bytes_ -= picture.cost;
        core_->wake.notify_all();
        if (picture.timeline != core_->timeline) {
          av_frame_free(&picture.frame);
          continue;
        }
        busy_ = true;
      }
      int result;
      try { result = convert_(picture.frame, picture.stream, picture.hardware, picture.timeline); }
      catch (...) { result = AVERROR_UNKNOWN; }
      av_frame_free(&picture.frame);
      bool failed = false;
      {
        std::lock_guard lock(core_->mutex);
        busy_ = false;
        if (result < 0 && picture.timeline == core_->timeline && !core_->stop) {
          int expected = 0;
          core_->decode_error.compare_exchange_strong(expected, result);
          core_->decode_abort = true;
          failed = true;
        }
        core_->wake.notify_all();
      }
      if (failed) { core_->io.cancel_media_io(core_->io.opaque); break; }
    }
  }
  RillightCoreImpl *core_;
  Convert convert_;
  std::thread thread_;
  std::deque<Picture> queue_;
  size_t bytes_ = 0;
  bool enabled_ = true, busy_ = false, stopped_ = false;
};

bool complete_mp4_header(AVFormatContext* format) {
  if (!format || !format->iformat || !format->iformat->name ||
      std::string_view(format->iformat->name).find("mov,mp4") != 0 ||
      (format->ctx_flags & AVFMTCTX_NOHEADER)) return false;
  bool video = false;
  int64_t duration = 0;
  for (unsigned int i = 0; i < format->nb_streams; ++i) {
    const auto* stream = format->streams[i];
    const auto* parameters = stream->codecpar;
    if (parameters->codec_type == AVMEDIA_TYPE_VIDEO &&
        !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
      if (parameters->codec_id != AV_CODEC_ID_H264 &&
          parameters->codec_id != AV_CODEC_ID_HEVC &&
          parameters->codec_id != AV_CODEC_ID_AV1 &&
          parameters->codec_id != AV_CODEC_ID_MPEG4) return false;
      if (parameters->width <= 0 || parameters->height <= 0 ||
          parameters->extradata_size <= 0 ||
          stream->nb_frames <= 0 || stream->duration <= 0 ||
          stream->time_base.num <= 0 || stream->time_base.den <= 0 ||
          (stream->avg_frame_rate.num <= 0 && stream->r_frame_rate.num <= 0))
        return false;
      video = true;
    } else if (parameters->codec_type == AVMEDIA_TYPE_AUDIO) {
      // Unknown MP4 sample entries cannot become playable by probing their
      // payload. They must not block fully described supported tracks.
      if (parameters->codec_id != AV_CODEC_ID_NONE &&
          (parameters->sample_rate <= 0 || parameters->ch_layout.nb_channels <= 0))
        return false;
    }
    if (stream->duration > 0 && stream->time_base.num > 0 && stream->time_base.den > 0)
      duration = std::max(duration, av_rescale_q(stream->duration,
                           stream->time_base, AVRational{1, AV_TIME_BASE}));
  }
  if (!video || duration <= 0) return false;
  if (format->duration == AV_NOPTS_VALUE) format->duration = duration;
  return true;
}

void run(RillightCoreImpl *core, uint64_t session) {
  AVFormatContext *format = avformat_alloc_context();
  Source *main_source = nullptr;
  Decoder video, audio, subtitle;
  VideoScale scale;
  PendingPackets pending_packets;
  VideoConvertLane conversion_lane(core);
  AudioFilter audio_filter;
  auto &subtitle_cues = core->subtitle_cues;
  auto &ass = core->ass;
  auto &subtitle_mutex = core->subtitle_mutex;
  { std::lock_guard lock(subtitle_mutex); subtitle_cues.clear(); }
  bool conversion_ready = false;
  VideoSink video_sink = [&](AVFrame *frame, int stream, uint32_t hardware,
                            uint64_t timeline) {
    // Validate the first hardware download synchronously so an unsupported
    // surface can still retry its retained packet with the software decoder.
    // After success, scale and staging buffers belong to the conversion lane.
    if (!conversion_ready) {
      const int result = convert_video_frame(core, format, frame, stream,
          hardware, &scale, &subtitle_cues, &ass, session, timeline,
          &subtitle_mutex);
      if (result >= 0) conversion_ready = true;
      return result;
    }
    return conversion_lane.Push(frame, stream, hardware, timeline);
  };
  DecodeLane video_lane(core, 16u * 1024u * 1024u, RILLIGHT_CORE_VIDEO_RGBA);
  DecodeLane audio_lane(core, 4u * 1024u * 1024u, RILLIGHT_CORE_AUDIO_S16);
  DecodeLane subtitle_lane(core, 2u * 1024u * 1024u, 0);
  int result = AVERROR(ENOMEM);
  bool ended = false;
  if (!format) goto finish;
  core->active_read_timeline = core->timeline_signal.load();
  format->opaque = core;
  format->interrupt_callback = AVIOInterruptCB{interrupt_read, core};
  format->io_open = nested_open;
  format->io_close2 = nested_close;

  main_source = open_source(core, core->url.c_str(), AVIO_FLAG_READ);
  if (!main_source) {
    result = core->owned_loopback ? core->owned_loopback->media_open_error.load() : 0;
    if (result >= 0) result = AVERROR(EIO);
    goto finish;
  }
  format->pb = main_source->avio;
  format->flags |= AVFMT_FLAG_CUSTOM_IO;

  result = avformat_open_input(&format, core->url.c_str(), nullptr, nullptr);
  if (result < 0) goto finish;
  // MP4 sample tables and codec configuration already describe complete VOD
  // streams. Probing every optional track can otherwise force distant network
  // reads before playback, even though the selected decoders can open now.
  // Fragmented/live/incomplete headers retain FFmpeg's full discovery path.
  if (!complete_mp4_header(format)) {
    result = avformat_find_stream_info(format, nullptr);
    if (result < 0) goto finish;
  }

  {
    const int vi = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1,
                                       nullptr, 0);
    const AVCodec *audio_codec = nullptr;
    const int ai = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1,
                                       &audio_codec, 0);
    result = restore_dovi_configuration(format, vi, &pending_packets);
    if (result < 0) goto finish;
    if (vi >= 0) {
      const auto *parameters = format->streams[vi]->codecpar;
      const auto *dovi = av_packet_side_data_get(
          parameters->coded_side_data, parameters->nb_coded_side_data,
          AV_PKT_DATA_DOVI_CONF);
      if (dovi && dovi->data &&
          dovi->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
        const auto *record =
            reinterpret_cast<const AVDOVIDecoderConfigurationRecord *>(dovi->data);
        bool unsupported = rillight_dovi_base_rejected(record->dv_profile,
                                        record->dv_bl_signal_compatibility_id) != 0;
        if (record->dv_profile == 5 && !record->el_present_flag)
          unsupported = false;
        if (unsupported) {
          result = RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI;
          goto finish;
        }
      }
    }
    {
      std::shared_ptr<void> window;
      { std::lock_guard lock(core->mutex); window = core->android_window; }
      video = make_decoder(format, vi, core->hardware_preference,
                           core->allow_software_fallback, window, core->android_dovi_profiles);
    }
    audio = make_decoder(format, ai);
    if ((vi >= 0 && !video.context) || (ai >= 0 && !audio.context)) {
      result = vi >= 0 && !video.context ? video.error : audio.error;
      if (!result) result = AVERROR_DECODER_NOT_FOUND;
      goto finish;
    }
    const int si = av_find_best_stream(format, AVMEDIA_TYPE_SUBTITLE,
                                       -1, -1, nullptr, 0);
    if (si >= 0) {
      const auto codec = format->streams[si]->codecpar->codec_id;
      if (bitmap_subtitle_codec(codec))
        subtitle = make_decoder(format, si);
#if RILLIGHT_HAVE_LIBASS
      else if (codec == AV_CODEC_ID_ASS && open_ass(&ass, format, si))
        subtitle.stream = si;
      else if (text_subtitle_codec(codec)) {
        subtitle = make_decoder(format, si);
        if (!subtitle.context || !open_text_ass(&ass, subtitle.context, si)) {
          avcodec_free_context(&subtitle.context);
          subtitle = {};
        }
      }
#endif
    }
    if (!video.context && !audio.context) {
      result = AVERROR_DECODER_NOT_FOUND;
      goto finish;
    }
    std::lock_guard lock(core->mutex);
    core->video_index = video.stream;
    core->android_color_buffers = video.android_color_buffers;
    const AVRational rate = video.stream >= 0
        ? av_guess_frame_rate(format, format->streams[video.stream], nullptr) : AVRational{0, 1};
    const double source_frame_rate = rate.den > 0 ? av_q2d(rate) : 0;
    core->video_frame_rate = std::isfinite(source_frame_rate) && source_frame_rate > 0 &&
        source_frame_rate <= 240 ? source_frame_rate : 0;
    core->audio_index = audio.stream;
    const char *demuxer = format->iformat ? format->iformat->name : nullptr;
    core->is_mp4_container = demuxer &&
        std::string_view(demuxer).find("mov,mp4") == 0;
    core->video_track_id = core->is_mp4_container && video.stream >= 0 &&
            format->streams[video.stream]->id > 0
        ? format->streams[video.stream]->id : -1;
    core->audio_track_id = core->is_mp4_container && audio.stream >= 0 &&
            format->streams[audio.stream]->id > 0
        ? format->streams[audio.stream]->id : -1;
    core->subtitle_index = subtitle.stream;
    core->duration = format->duration == AV_NOPTS_VALUE ? -1 : format->duration;
    core->tracks.clear();
#if RILLIGHT_HAVE_LIBASS
    core->embedded_stream_count = format->nb_streams;
#endif
    for (unsigned int index = 0; index < format->nb_streams; ++index) {
      const auto codec = format->streams[index]->codecpar->codec_id;
      const auto type = format->streams[index]->codecpar->codec_type;
      if (type == AVMEDIA_TYPE_SUBTITLE &&
          !bitmap_subtitle_codec(codec)
#if RILLIGHT_HAVE_LIBASS
          && codec != AV_CODEC_ID_ASS && !text_subtitle_codec(codec)
#endif
          ) continue;
      if (type == AVMEDIA_TYPE_SUBTITLE &&
          (bitmap_subtitle_codec(codec)
#if RILLIGHT_HAVE_LIBASS
           || text_subtitle_codec(codec)
#endif
          ) &&
          !avcodec_find_decoder(codec)) continue;
      auto track = make_track(format->streams[index]);
      if (track.type != 0) core->tracks.push_back(track);
    }
  }
  if (!conversion_lane.Start([&](AVFrame *frame, int stream, uint32_t hardware, uint64_t timeline) {
    return convert_video_frame(core, format, frame, stream, hardware, &scale,
                               &subtitle_cues, &ass, session, timeline, &subtitle_mutex);
  })) { result = AVERROR(ENOMEM); goto finish; }
  if (!video_lane.Start([&](const AVPacket *packet, uint64_t timeline) {

      int result = decode_packet(core, format, video, packet, video.stream,
                             &scale, &audio_filter, &subtitle_cues, &ass,
                             core->external_audio_speed ? 1.0 : core->speed, session,
                             timeline, &subtitle_mutex, &video_sink);
      if (packet && result < 0 && video.hardware != RILLIGHT_CORE_HW_NONE &&
          core->allow_software_fallback) {
        // A configured device can still reject the stream profile when the
        // first packet is decoded. Retry that retained packet in software;
        // the replacement decoder has no device preference, so this is
        // bounded to one fallback for this stream.
        Decoder replacement = make_decoder(format, video.stream);
        if (replacement.context) {
          avcodec_free_context(&video.context);
          video = replacement;
          {
            std::lock_guard lock(core->mutex);
            core->android_color_buffers = video.android_color_buffers;
            for (auto &track : core->tracks) {
              if (track.stream_index == video.stream)
                track.actual_hardware = RILLIGHT_CORE_HW_NONE;
            }
          }
          result = decode_packet(core, format, video, packet, video.stream,
                                 &scale, &audio_filter, &subtitle_cues, &ass,
                                 core->external_audio_speed ? 1.0 : core->speed, session, timeline, &subtitle_mutex, &video_sink);
        }
      }

      return result;
    }) || !audio_lane.Start([&](const AVPacket *packet, uint64_t timeline) {
      int result = decode_packet(core, format, audio, packet, video.stream,
          &scale, &audio_filter, &subtitle_cues, &ass,
          core->external_audio_speed ? 1.0 : core->speed, session, timeline);
      if (result >= 0 && !packet && audio_filter.graph) {
        result = av_buffersrc_add_frame_flags(audio_filter.source, nullptr, 0);
        if (result >= 0) result = drain_audio_filter(core, &audio_filter,
            video.stream, session, timeline);
      }
      return result;
    }) || !subtitle_lane.Start([&](const AVPacket *packet, uint64_t) {
      if (!packet) return 0;
      std::lock_guard lock(subtitle_mutex);
      int result = 0;

      if (subtitle.context) {
        const auto codec =
            format->streams[subtitle.stream]->codecpar->codec_id;
        if (bitmap_subtitle_codec(codec))
          result = decode_bitmap_subtitle(subtitle, packet,
              format->streams[subtitle.stream]->time_base, &subtitle_cues);
#if RILLIGHT_HAVE_LIBASS
        else if (text_subtitle_codec(codec) && ass.track)
          result = decode_text_subtitle(subtitle, packet,
              format->streams[subtitle.stream]->time_base, &ass);
#endif
      }
#if RILLIGHT_HAVE_LIBASS
      else if (ass.track)
        process_ass(&ass, packet,
                    format->streams[subtitle.stream]->time_base);
#endif

      return result;
    })) { result = AVERROR(ENOMEM); goto finish; }

  while (!core->stop) {
    uint64_t timeline;
    int64_t seek;
    int selected_audio;
    bool change_audio;
    bool change_subtitle;
    int selected_subtitle;
    bool change_speed;
    double selected_speed;
    {
      std::unique_lock lock(core->mutex);
      // A paused timeline only needs its first frame. Keep the decoder asleep
      // after that frame instead of filling both output queues while the
      // surface and audio device are idle. A seek resets first_* and changes
      // the timeline, so it can decode a fresh preview before sleeping again.
      core->wake.wait(lock, [&] {
        // A detached Android Surface is a presentation interruption. Do not
        // reopen MediaCodec in byte-buffer mode while the replacement view is
        // being mounted; that would discard the HDR path and can terminate
        // the current seek before the new Surface arrives.
        if (core->hardware_preference == RILLIGHT_CORE_HW_MEDIACODEC &&
            video.stream >= 0 && !core->android_window)
          return core->stop || core->decode_abort;
        return core->stop || core->decode_abort || core->play_intent ||
               core->seek_target >= 0 || core->audio_change ||
               core->subtitle_change || core->speed_change ||
               !(video.stream >= 0 ? core->first_video : core->first_audio);
      });
      if (core->stop || core->decode_abort) break;
      timeline = core->timeline;
      seek = core->seek_target;
      core->seek_target = -1;
      change_audio = core->audio_change;
      selected_audio = core->requested_audio;
      core->audio_change = false;
      change_subtitle = core->subtitle_change;
      selected_subtitle = core->requested_subtitle;
      core->subtitle_change = false;
      change_speed = core->speed_change;
      selected_speed = core->requested_speed;
      core->speed_change = false;
    }
    core->active_read_timeline = timeline;
    const bool subtitle_off_only = change_subtitle && selected_subtitle == -1 &&
        seek < 0 && !change_audio && !change_speed;
    const bool reconfigure = seek >= 0 || change_audio || change_subtitle || change_speed;
    if (reconfigure) {
      if (!subtitle_off_only) {
        video_lane.Quiesce();
        conversion_lane.Quiesce();
        audio_lane.Quiesce();
      }
      subtitle_lane.Quiesce();
    }
    if (seek >= 0) {
      {
        std::lock_guard lock(core->mutex);
        if (core->timeline != timeline) continue;
        core->media_io_active = true;
      }
      if (format->pb) {
        format->pb->error = 0;
        format->pb->eof_reached = 0;
      }
      pending_packets.Clear();
      result = av_seek_frame(format, -1, seek, AVSEEK_FLAG_BACKWARD);
      {
        std::lock_guard lock(core->mutex);
        core->media_io_active = false;
        if (core->timeline != timeline) {
          if (format->pb) {
            format->pb->error = 0;
            format->pb->eof_reached = 0;
          }
          continue;
        }
      }
      if (result < 0) break;
      if (video.context && video.hardware == RILLIGHT_CORE_HW_MEDIACODEC &&
          !video.android_color_buffers) {
        // Some Android Codec2 implementations stop producing pictures after
        // flush during an audio/subtitle/rate seek. All decode/conversion lanes
        // are quiescent here, so retire the codec and create a fresh instance
        // with the same hardware policy instead of leaving recovery stalled.
        const int stream = video.stream;
        avcodec_free_context(&video.context);
        {
          std::shared_ptr<void> window;
          { std::lock_guard lock(core->mutex); window = core->android_window; }
          video = make_decoder(format, stream, core->hardware_preference,
                               core->allow_software_fallback, window, core->android_dovi_profiles,
                               std::max<int64_t>(0, seek - 5000));
        }
        if (!video.context) {
          result = video.error < 0 ? video.error : AVERROR_DECODER_NOT_FOUND;
          break;
        }
        conversion_ready = false;
        std::lock_guard lock(core->mutex);
        core->android_color_buffers = video.android_color_buffers;
        for (auto& track : core->tracks) {
          if (track.stream_index == stream)
            track.actual_hardware = RILLIGHT_CORE_HW_NONE;
        }
      } else if (video.context) {
        if (video.android_color_buffers) {
          // Byte output owns its pixels; no outstanding decoder Surface buffers
          // delay flushing. Preserve parameter sets learned from in-band HEVC,
          // and update the preroll cutoff in both directions on every seek.
          result = av_opt_set_int(video.context->priv_data, "discard_before",
                                   std::max<int64_t>(0, seek - 5000), 0);
          if (result < 0) break;
        }
        avcodec_flush_buffers(video.context);
      }
      if (audio.context) avcodec_flush_buffers(audio.context);
      audio.dts_recovery.reset();
      if (subtitle.context) avcodec_flush_buffers(subtitle.context);
      close_audio_filter(&audio_filter);
      std::lock_guard subtitle_lock(subtitle_mutex);
      subtitle_cues.clear();
#if RILLIGHT_HAVE_LIBASS
      if (ass.track && !ass.external) ass_flush_events(ass.track);
#endif
    }
    if (change_audio) {
      Decoder replacement = make_decoder(format, selected_audio);
      if (replacement.context &&
          format->streams[selected_audio]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
        avcodec_free_context(&audio.context);
        audio = replacement;
        close_audio_filter(&audio_filter);
        std::lock_guard lock(core->mutex);
        core->audio_index = selected_audio;
        core->audio_track_id = core->is_mp4_container &&
                format->streams[selected_audio]->id > 0
            ? format->streams[selected_audio]->id : -1;
        core->error = 0;
      } else {
        avcodec_free_context(&replacement.context);
        std::lock_guard lock(core->mutex);
        core->error = replacement.error < 0 ? replacement.error :
                                                AVERROR_DECODER_NOT_FOUND;
      }
    }
    if (change_subtitle) {
      Decoder replacement;
      bool ass_selected = false;
#if RILLIGHT_HAVE_LIBASS
      AssRenderer replacement_ass;
#endif
      if (selected_subtitle >= 0 &&
          selected_subtitle < static_cast<int>(format->nb_streams) &&
          format->streams[selected_subtitle]->codecpar->codec_type ==
              AVMEDIA_TYPE_SUBTITLE) {
        const auto codec =
            format->streams[selected_subtitle]->codecpar->codec_id;
        if (bitmap_subtitle_codec(codec))
          replacement = make_decoder(format, selected_subtitle);
#if RILLIGHT_HAVE_LIBASS
        else if (codec == AV_CODEC_ID_ASS &&
                 open_ass(&replacement_ass, format, selected_subtitle)) {
          replacement.stream = selected_subtitle;
          ass_selected = true;
        }
        else if (text_subtitle_codec(codec)) {
          replacement = make_decoder(format, selected_subtitle);
          if (replacement.context &&
              open_text_ass(&replacement_ass, replacement.context,
                            selected_subtitle))
            ass_selected = true;
          else {
            avcodec_free_context(&replacement.context);
            replacement = {};
          }
        }
#endif
      }
#if RILLIGHT_HAVE_LIBASS
      if (!replacement.context && !ass_selected) {
        std::shared_ptr<const std::vector<char>> script;
        std::shared_ptr<const std::vector<ExternalTextCue>> cues;
        AVCodecID external_codec = AV_CODEC_ID_NONE;
        {
          std::lock_guard lock(core->mutex);
          for (const auto &external : core->external_subtitles) {
            if (external.stream_index == selected_subtitle) {
              script = external.script;
              cues = external.cues;
              external_codec = external.codec;
              break;
            }
          }
        }
        const bool opened = script &&
            (external_codec == AV_CODEC_ID_ASS ?
             open_external_ass(&replacement_ass, *script,
                               selected_subtitle) :
             cues && open_external_text(&replacement_ass, *script, *cues,
                                         selected_subtitle));
        if (opened) {
          replacement.stream = selected_subtitle;
          ass_selected = true;
        }
      }
#endif
      if (selected_subtitle == -1 || replacement.context || ass_selected) {
        avcodec_free_context(&subtitle.context);
        subtitle = replacement;
        {
        std::lock_guard subtitle_lock(subtitle_mutex);
        subtitle_cues.clear();
        close_ass(&ass);
#if RILLIGHT_HAVE_LIBASS
        if (ass_selected) ass = replacement_ass;
#endif
        }
        std::lock_guard lock(core->mutex);
        core->subtitle_index = subtitle.stream;
        core->error = 0;
      } else {
        std::lock_guard lock(core->mutex);
        core->error = AVERROR_DECODER_NOT_FOUND;
      }
    }
    if (change_speed) {
      close_audio_filter(&audio_filter);
      std::lock_guard lock(core->mutex);
      core->speed = selected_speed;
    }
    // Do not seek/read the payload of every unselected MP4 audio track.
    // Keep their headers and indices so a later selection can re-enable them.
    for (unsigned i = 0; i < format->nb_streams; ++i) {
      format->streams[i]->discard =
          static_cast<int>(i) == video.stream ||
          static_cast<int>(i) == audio.stream ||
          static_cast<int>(i) == subtitle.stream
              ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
    }
    conversion_lane.Resume();
    video_lane.Resume();
    audio_lane.Resume();
    subtitle_lane.Resume();
    AVPacket *packet = av_packet_alloc();
    if (!packet) { result = AVERROR(ENOMEM); break; }
    {
      std::lock_guard lock(core->mutex);
      if (core->timeline != timeline) {
        av_packet_free(&packet);
        continue;
      }
      core->media_io_active = true;
    }
    if (!pending_packets.values.empty()) {
      AVPacket* saved = pending_packets.values.front();
      pending_packets.values.pop_front();
      av_packet_move_ref(packet, saved);
      av_packet_free(&saved);
      result = 0;
    } else result = av_read_frame(format, packet);
    {
      std::lock_guard lock(core->mutex);
      core->media_io_active = false;
      if (core->timeline != timeline) {
        av_packet_free(&packet);
        if (format->pb) {
          format->pb->error = 0;
          format->pb->eof_reached = 0;
        }
        continue;
      }
    }
    if (core->decode_abort) { av_packet_free(&packet); break; }
    const int fatal_io_error = core->io_fatal_error.load();
    if (fatal_io_error < 0) {
      av_packet_free(&packet);
      result = fatal_io_error;
      break;
    }
    if (result == AVERROR(EAGAIN)) {
      av_packet_free(&packet);
      {
        std::lock_guard lock(core->mutex);
        // A stalled demuxer must not freeze frames already queued for future
        // presentation. Otherwise their deadlines can never be reached, and
        // no new decoded frame may arrive to resume the playback clock.
        const int64_t position = playback_position(core);
        if (core->state == RILLIGHT_CORE_PLAYING && core->video.empty() &&
            core->audio.empty() &&
            (!core->audio_clock_active || position >= core->audio_clock_limit)) {
          core->base_position = position;
          core->base_time = Clock::now();
          core->state = RILLIGHT_CORE_BUFFERING;
        }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
      continue;
    }
    if (result == AVERROR_EOF) {
      av_packet_free(&packet);
      {
        std::lock_guard lock(core->mutex);
        if (core->timeline != timeline) continue;
        // Decoder queues may still contain seconds of data. Keep track and
        // subtitle commands available until both lanes have drained.
      }
      result = video_lane.Push(nullptr, timeline);
      if (result >= 0) result = audio_lane.Push(nullptr, timeline);
      if (result < 0) break;
      video_lane.Drain(timeline);
      conversion_lane.Drain(timeline);
      audio_lane.Drain(timeline);
      subtitle_lane.Drain(timeline);
      if (core->decode_abort) { result = core->decode_error.load(); break; }
      std::unique_lock lock(core->mutex);
      if (core->timeline != timeline) continue;
      core->input_exhausted = true;
      core->eof = true;
      core->wake.wait(lock, [&] {
        return core->stop || core->timeline != timeline ||
               (core->video.empty() && core->audio.empty() &&
                core->output_drained);
      });
      if (core->stop) break;
      if (core->timeline != timeline) continue;
      ended = true;
      result = 0;
      break;
    }
    if (result < 0) { av_packet_free(&packet); break; }
    if (packet->stream_index == video.stream)
      result = video_lane.Push(packet, timeline);
    else if (packet->stream_index == audio.stream)
      result = audio_lane.Push(packet, timeline);
    else if (packet->stream_index == subtitle.stream)
      result = subtitle_lane.Push(packet, timeline);
    else result = 0;
    av_packet_free(&packet);
    if (result < 0) break;
  }
finish:

  core->decode_abort = true;
  core->wake.notify_all();
  video_lane.Stop();
  conversion_lane.Stop();
  audio_lane.Stop();
  subtitle_lane.Stop();
  if (core->decode_error < 0) result = core->decode_error.load();
  // The last displayed clean frame outlives decoding (including EOF). Keep its
  // subtitle events/fonts until the session is replaced or destroyed so a
  // paused viewport/PiP redraw cannot erase still-active glyphs.
  close_audio_filter(&audio_filter);
  avcodec_free_context(&video.context);
  avcodec_free_context(&audio.context);
  avcodec_free_context(&subtitle.context);
  if (format) avformat_close_input(&format);
  close_source(main_source);
  std::lock_guard lock(core->mutex);
  if (!core->stop && core->session == session) {
    core->error = ended ? 0 : (result < 0 ? result : AVERROR_UNKNOWN);
    core->state = ended ? RILLIGHT_CORE_ENDED : RILLIGHT_CORE_FAILED;
  }
  core->wake.notify_all();
}

void stop_worker(RillightCoreImpl *core) {
  core->stop = true;
  core->wake.notify_all();
  if ((core->worker.joinable() || core->subtitle_loader.joinable()) &&
      core->io.cancel) core->io.cancel(core->io.opaque);
  if (core->worker.joinable()) core->worker.join();
  if (core->subtitle_loader.joinable()) core->subtitle_loader.join();
}
}  // namespace

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

RILLIGHT_DOVI_TEST_API int rillight_dovi_base_rejected(int profile,
                                                       int compatibility) {
  if (profile < 0) return 0;
  // Profile 5 is IPT with no base. Compatibility 1 and 6 are HDR10
  // (Profile 7 uses 6), 2 is SDR, and 4 is HLG.
  if (profile == 5) return 1;
  return compatibility != 1 && compatibility != 2 && compatibility != 4 &&
         compatibility != 6;
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

int rillight_core_render_mediacodec_frame(const RillightCoreFrame* frame) {
#if defined(__ANDROID__)
  if (!frame || frame->type != RILLIGHT_CORE_VIDEO_MEDIACODEC) return -1;
  if (static_cast<const VideoOutputFrame*>(frame)->subtitle_redraw) return 0;
  const auto& decoded = static_cast<const VideoOutputFrame*>(frame)->codec_frame;
  if (!decoded || !decoded->data[3]) return -1;
  return av_mediacodec_release_buffer(
      reinterpret_cast<AVMediaCodecBuffer*>(decoded->data[3]), 1);
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
                                            int hdr_display_supported) {
#if defined(__ANDROID__)
  if (!frame || !native_window || frame->type != RILLIGHT_CORE_VIDEO_ANDROID_P010) return -1;
  const auto& decoded = static_cast<const VideoOutputFrame*>(frame)->codec_frame;
  if (!decoded) return -1;
  if (!android_color_renderer) android_color_renderer = std::make_unique<AndroidColorPipeline>();
  return android_color_renderer->Render(decoded.get(), static_cast<ANativeWindow*>(native_window),
                                        hdr_display_supported != 0) ? 0 : -1;
#else
  (void)frame; (void)native_window; (void)hdr_display_supported;
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
#if defined(_WIN32)
  core->gpu_video = enabled != 0;
  return 0;
#else
  return enabled ? -1 : 0;
#endif
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
    { std::lock_guard subtitle_lock(core->subtitle_mutex); close_ass(&core->ass); }
    core->stop = false;
    core->decode_abort = false;
    core->decode_error = 0;
    core->media_io_active = false;
    ++core->session;
    core->subtitle_presentation = {};
    ++core->timeline;
    core->timeline_signal = core->timeline;
    core->url = url;
    core->video_index = core->audio_index = core->subtitle_index = -1;
    core->video_frame_rate = 0;
    core->android_color_buffers = false;
    core->is_mp4_container = false;
    core->video_track_id = core->audio_track_id = -1;
    core->duration = -1;
    core->base_position = position_us;
    core->base_time = Clock::now();
    core->seek_target = position_us > 0 ? position_us : -1;
    core->audio_change = false;
    core->requested_audio = -1;
    core->subtitle_change = false;
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
  if (!pointer || stream_index < -1) return -1;
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
  if (!accept_operation(core, operation_id)) return -1;
  if (core->subtitle_index == stream_index &&
      (!core->subtitle_change || core->requested_subtitle == stream_index))
    return 0;
  if (core->input_exhausted) return -1;
  if (stream_index == -1 && !core->subtitle_change &&
      core->state != RILLIGHT_CORE_RECOVERING) {
    // Hiding captions needs no media seek or codec flush. Publish the choice
    // immediately, including while paused or waiting for network data; the
    // demux worker retires only the subtitle decoder at its next safe point.
    core->subtitle_index = -1;
    core->requested_subtitle = -1;
    core->subtitle_change = true;
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
  core->requested_subtitle = stream_index;
  core->subtitle_change = true;
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
    // The sink changes the rate of unmodified PCM already in its queue.
    // Re-anchor clock interpolation without seeking or retiring video/RPU.
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
  core->volume = gain;
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
  if (core->audio_clock_handed_off && reported_position < current_position)
    return -1;
  core->audio_clock_active = true;
  core->audio_clock_limit = queued_end_pts_us;
  core->audio_clock_handed_off = false;
  core->base_position = std::max(current_position, reported_position);
  core->base_time = now;
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
  snapshot->duration_us = core->duration;
  snapshot->position_us = playback_position(core);
  snapshot->first_video_frame_ready = core->first_video;
  snapshot->first_audio_frame_ready = core->first_audio;
  snapshot->source_eof = core->eof;
  snapshot->queued_video_frames = static_cast<int>(core->video.size());
  snapshot->queued_audio_frames = static_cast<int>(core->audio.size());
  snapshot->playback_speed = core->speed;
  snapshot->preferred_hardware = core->hardware_preference;
  snapshot->allow_software_fallback = core->allow_software_fallback;
  snapshot->external_subtitle_pending = core->external_subtitle_pending;
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
    if (core->subtitle_index < 0) return frame;
    std::lock_guard subtitle_lock(core->subtitle_mutex);
    core->subtitle_cues.erase(std::remove_if(core->subtitle_cues.begin(),
        core->subtitle_cues.end(), [frame](const SubtitleCue &cue) {
          return cue.end_us < frame->pts_us;
        }), core->subtitle_cues.end());
    apply_subtitle_presentation(&core->ass, frame->width, frame->height,
                                core->subtitle_presentation);
    if (frame->type == RILLIGHT_CORE_VIDEO_RGBA) {
      blend_subtitles(frame, core->subtitle_cues);
      blend_ass(frame, &core->ass);
    } else {
      const int bytes = frame->data_size;
      render_gpu_subtitles(frame, core->subtitle_cues, &core->ass,
                           &core->bitmap_subtitle_cache);
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
  if (type != RILLIGHT_CORE_VIDEO_RGBA && type != RILLIGHT_CORE_VIDEO_D3D11 &&
      type != RILLIGHT_CORE_VIDEO_MEDIACODEC && type != RILLIGHT_CORE_VIDEO_ANDROID_P010 &&
      type != RILLIGHT_CORE_AUDIO_S16)
    return nullptr;
  if (type == RILLIGHT_CORE_AUDIO_S16 &&
      core->state == RILLIGHT_CORE_RECOVERING && core->video_index >= 0 &&
      !core->first_video)
    return nullptr;
  if (type != RILLIGHT_CORE_AUDIO_S16 && core->subtitle_redraw && core->displayed_clean) {
    auto *redraw = core->subtitle_preview;
    if (type == RILLIGHT_CORE_VIDEO_RGBA && redraw &&
        redraw->type != RILLIGHT_CORE_VIDEO_RGBA &&
        redraw->type != RILLIGHT_CORE_VIDEO_RGBA16F) return nullptr;
    core->subtitle_preview = nullptr;
    core->subtitle_redraw = false;
    return redraw;
  }
  auto &queue = type != RILLIGHT_CORE_AUDIO_S16 ? core->video : core->audio;
  auto &bytes = type != RILLIGHT_CORE_AUDIO_S16 ? core->video_bytes : core->audio_bytes;
  if (queue.empty()) {
    if (type != RILLIGHT_CORE_AUDIO_S16 && core->first_video &&
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
  if (type != RILLIGHT_CORE_AUDIO_S16 && queue.front()->pts_us >= 0) {
    const int64_t clock_us = playback_position(core);
    while (queue.size() > 1 && queue[1]->pts_us >= 0 &&
           queue[1]->pts_us + 100000 < clock_us) {
      auto *late = queue.front();
      queue.pop_front();
      bytes -= late->data_size;
      rillight_core_release_frame(late);
    }
    if (queue.front()->pts_us > clock_us + 10000 &&
        !(core->state == RILLIGHT_CORE_PAUSED &&
          !core->paused_video_frame_emitted)) return nullptr;
  }
  if (type == RILLIGHT_CORE_VIDEO_RGBA &&
      queue.front()->type != RILLIGHT_CORE_VIDEO_RGBA &&
      queue.front()->type != RILLIGHT_CORE_VIDEO_RGBA16F) return nullptr;
  auto *frame = queue.front();
  queue.pop_front();
  bytes -= frame->data_size;
  if (type == RILLIGHT_CORE_AUDIO_S16 && core->volume != 1.0) {
    auto *samples = reinterpret_cast<int16_t *>(frame->data);
    const int count = frame->data_size / sizeof(int16_t);
    for (int index = 0; index < count; ++index) {
      const double value = std::round(samples[index] * core->volume);
      samples[index] = static_cast<int16_t>(std::clamp(value, -32768.0, 32767.0));
    }
  }
  if (type != RILLIGHT_CORE_AUDIO_S16) {
    core->paused_video_frame_emitted = true;
    rillight_core_release_frame(core->displayed_clean);
    core->displayed_clean = nullptr;
    if (core->subtitle_index >= 0) {
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
  if (frame->type != RILLIGHT_CORE_AUDIO_S16) {
    auto *video = static_cast<VideoOutputFrame *>(frame);
    if (video->data) video->buffers->Recycle(video->data, video->data_size);
    delete video;
    return;
  }
  delete[] frame->data;
  delete frame;
}
}  // extern "C"
