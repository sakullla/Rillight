#include "rillight_core.h"

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
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <utility>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/aes.h>
#include <libavutil/channel_layout.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#if RILLIGHT_HAVE_LIBASS
#include <ass/ass.h>
#endif
}

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

struct Decoder {
  AVCodecContext *context = nullptr;
  int stream = -1;
  std::shared_ptr<AVPixelFormat> hw_format;
  uint32_t hardware = RILLIGHT_CORE_HW_NONE;
  int error = 0;
};

struct AudioFilter {
  AVFilterGraph *graph = nullptr;
  AVFilterContext *source = nullptr;
  AVFilterContext *sink = nullptr;
  int input_rate = 0;
  AVSampleFormat input_format = AV_SAMPLE_FMT_NONE;
  AVChannelLayout input_layout{};
  double speed = 1.0;
  int64_t media_anchor = -1;
  int64_t output_anchor = -1;
  int64_t next_media_pts = -1;
};

struct SubtitleBitmap {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
  std::vector<uint8_t> indices;
  std::vector<uint32_t> palette;
};

struct SubtitleCue {
  int64_t start_us = 0;
  int64_t end_us = 0;
  std::vector<SubtitleBitmap> bitmaps;
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
};

void close_ass(AssRenderer *ass) {
  if (ass->track) ass_free_track(ass->track);
  if (ass->renderer) ass_renderer_done(ass->renderer);
  if (ass->library) ass_library_done(ass->library);
  *ass = {};
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
  ass_set_fonts(replacement.renderer, nullptr, "sans-serif",
                ASS_FONTPROVIDER_AUTODETECT, nullptr, 1);
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
  ass_set_fonts(replacement.renderer, nullptr, "sans-serif",
                ASS_FONTPROVIDER_AUTODETECT, nullptr, 1);
  replacement.stream = stream_index;
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
  ass_set_fonts(replacement.renderer, nullptr, "sans-serif",
                ASS_FONTPROVIDER_AUTODETECT, nullptr, 1);
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
  ass_set_fonts(replacement.renderer, nullptr, "sans-serif",
                ASS_FONTPROVIDER_AUTODETECT, nullptr, 1);
  replacement.stream = stream_index;
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
  filter->media_anchor = -1;
  filter->output_anchor = -1;
  filter->next_media_pts = -1;
}

struct RillightCoreImpl {
  explicit RillightCoreImpl(const RillightCoreIo &source_io) : io(source_io) {}
  RillightCoreIo io;
  std::mutex mutex;
  std::mutex lifecycle_mutex;
  std::condition_variable wake;
  std::thread worker;
  std::thread subtitle_loader;
  std::atomic<bool> stop{false};
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
  bool eof = false;
  bool input_exhausted = false;
  bool output_drained = false;
  int error = 0;
  int video_index = -1;
  int audio_index = -1;
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
  double requested_speed = 1.0;
  bool speed_change = false;
  RillightCoreHardware hardware_preference = RILLIGHT_CORE_HW_NONE;
  bool allow_software_fallback = true;
  size_t video_bytes = 0;
  size_t audio_bytes = 0;
  std::string url;
};

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
    if (count < 0) { result = count; break; }
    if (count == 0) break;
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
    delete[] frame->data;
    delete frame;
  }
  bytes = 0;
}

void reset_frames(RillightCoreImpl *core) {
  clear_queue(core->video, core->video_bytes);
  clear_queue(core->audio, core->audio_bytes);
  core->first_video = false;
  core->first_audio = false;
  core->eof = false;
  core->input_exhausted = false;
  core->output_drained = false;
  core->audio_clock_active = false;
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
  return core->stop.load() ||
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
  if (!source->aes)
    return source->io.seek(source->io.opaque, source->handle, offset, whence);
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
  const auto wanted = *static_cast<AVPixelFormat *>(context->opaque);
  for (const AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE;
       ++format) {
    if (*format == wanted) return *format;
  }
  return AV_PIX_FMT_NONE;
}

Decoder make_decoder(AVFormatContext *format, int index,
                     RillightCoreHardware preference = RILLIGHT_CORE_HW_NONE,
                     bool allow_software_fallback = true) {
  Decoder result;
  if (index < 0 || index >= static_cast<int>(format->nb_streams)) return result;
  const auto *parameters = format->streams[index]->codecpar;
  const AVCodec *codec = avcodec_find_decoder(parameters->codec_id);
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
  if (parameters->codec_type == AVMEDIA_TYPE_SUBTITLE)
    context->pkt_timebase = format->streams[index]->time_base;
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
      device_error = av_hwdevice_ctx_create(&device, device_type, nullptr,
                                             nullptr, 0);
      if (device_error >= 0) {
        context->hw_device_ctx = device;
        result.hw_format = std::make_shared<AVPixelFormat>(selected->pix_fmt);
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
  return result;
}

bool bitmap_subtitle_codec(AVCodecID codec) {
  return codec == AV_CODEC_ID_HDMV_PGS_SUBTITLE ||
         codec == AV_CODEC_ID_DVB_SUBTITLE ||
         codec == AV_CODEC_ID_DVD_SUBTITLE || codec == AV_CODEC_ID_XSUB;
}

#if RILLIGHT_HAVE_LIBASS
bool text_subtitle_codec(AVCodecID codec) {
  return codec == AV_CODEC_ID_SUBRIP || codec == AV_CODEC_ID_WEBVTT;
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
                                 SwsContext **scale) {
  if (frame->width <= 0 || frame->height <= 0 ||
      frame->width > static_cast<int>(kMaxVideoBytes / 4))
    return nullptr;
  const int stride = frame->width * 4;
  const int bytes = av_image_get_buffer_size(AV_PIX_FMT_RGBA, frame->width,
                                              frame->height, 1);
  if (bytes <= 0 || static_cast<size_t>(bytes) > kMaxVideoBytes) return nullptr;
  *scale = sws_getCachedContext(*scale, frame->width, frame->height,
                                 static_cast<AVPixelFormat>(frame->format),
                                 frame->width, frame->height, AV_PIX_FMT_RGBA,
                                 SWS_BILINEAR, nullptr, nullptr, nullptr);
  if (!*scale) return nullptr;
  const AVColorRange source_range =
      frame->color_range != AVCOL_RANGE_UNSPECIFIED ? frame->color_range :
      stream->codecpar->color_range;
  const AVColorSpace source_space =
      frame->colorspace != AVCOL_SPC_UNSPECIFIED ? frame->colorspace :
      stream->codecpar->color_space;
  int sws_space = SWS_CS_DEFAULT;
  if (source_space == AVCOL_SPC_BT709) sws_space = SWS_CS_ITU709;
  else if (source_space == AVCOL_SPC_BT2020_NCL) sws_space = SWS_CS_BT2020;
  const int *coefficients = sws_getCoefficients(sws_space);
  if (sws_setColorspaceDetails(*scale, coefficients,
          source_range == AVCOL_RANGE_JPEG, coefficients, 1,
          0, 1 << 16, 1 << 16) < 0) return nullptr;
  auto *output = new (std::nothrow) RillightCoreFrame{};
  if (!output) return nullptr;
  output->data = new (std::nothrow) uint8_t[bytes];
  if (!output->data) {
    delete output;
    return nullptr;
  }
  uint8_t *planes[4] = {output->data, nullptr, nullptr, nullptr};
  int lines[4] = {stride, 0, 0, 0};
  if (sws_scale(*scale, frame->data, frame->linesize, 0, frame->height,
                planes, lines) <= 0) {
    delete[] output->data;
    delete output;
    return nullptr;
  }
  output->struct_size = sizeof(*output);
  output->type = RILLIGHT_CORE_VIDEO_RGBA;
  output->session_id = session;
  output->timeline_version = timeline;
  output->pts_us = pts;
  output->width = frame->width;
  output->height = frame->height;
  output->stride = stride;
  output->data_size = bytes;
  AVRational sar = frame->sample_aspect_ratio;
  if (sar.num <= 0 || sar.den <= 0) sar = stream->sample_aspect_ratio;
  if (sar.num <= 0 || sar.den <= 0)
    sar = stream->codecpar->sample_aspect_ratio;
  if (sar.num <= 0 || sar.den <= 0) sar = AVRational{1, 1};
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
  AVFilterContext *format = nullptr;
  int result = avfilter_graph_create_filter(
      &filter->source, avfilter_get_by_name("abuffer"), "input", args,
      nullptr, filter->graph);
  if (result < 0) return result;
  const std::string tempo_arg = std::to_string(speed);
  result = avfilter_graph_create_filter(
      &tempo, avfilter_get_by_name("atempo"), "tempo", tempo_arg.c_str(),
      nullptr, filter->graph);
  if (result < 0) return result;
  result = avfilter_graph_create_filter(
      &format, avfilter_get_by_name("aformat"), "format",
      "sample_fmts=s16:sample_rates=48000:channel_layouts=stereo",
      nullptr, filter->graph);
  if (result < 0) return result;
  result = avfilter_graph_create_filter(
      &filter->sink, avfilter_get_by_name("abuffersink"), "output", nullptr,
      nullptr, filter->graph);
  if (result < 0) return result;
  result = avfilter_link(filter->source, 0, tempo, 0);
  if (result < 0) return result;
  result = avfilter_link(tempo, 0, format, 0);
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
  filter->output_anchor = -1;
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
  if (frame->pts != AV_NOPTS_VALUE && filter->media_anchor >= 0) {
    const int64_t output_pts = av_rescale_q(
        frame->pts, av_buffersink_get_time_base(filter->sink),
        AVRational{1, 1000000});
    if (filter->output_anchor < 0) filter->output_anchor = output_pts;
    pts = filter->media_anchor + static_cast<int64_t>(
                                     (output_pts - filter->output_anchor) *
                                     filter->speed);
  }
  filter->next_media_pts = pts < 0 ? -1 :
      pts + static_cast<int64_t>(frame->nb_samples * 1000000.0 /
                                 48000.0 * filter->speed);
  output->struct_size = sizeof(*output);
  output->type = RILLIGHT_CORE_AUDIO_S16;
  output->session_id = session;
  output->timeline_version = timeline;
  output->pts_us = pts;
  output->sample_rate = 48000;
  output->channels = 2;
  output->sample_count = frame->nb_samples;
  output->data_size = bytes;
  return output;
}

void enqueue(RillightCoreImpl *core, RillightCoreFrame *frame,
             int video_index, uint64_t timeline) {
  if (!frame) return;
  std::unique_lock lock(core->mutex);
  auto &queue = frame->type == RILLIGHT_CORE_VIDEO_RGBA ? core->video : core->audio;
  auto &bytes = frame->type == RILLIGHT_CORE_VIDEO_RGBA ? core->video_bytes : core->audio_bytes;
  if (core->state == RILLIGHT_CORE_RECOVERING && frame->pts_us >= 0 &&
      frame->pts_us + (frame->type == RILLIGHT_CORE_VIDEO_RGBA ? 5000 : 20000) <
          core->base_position) {
    lock.unlock();
    rillight_core_release_frame(frame);
    return;
  }
  const auto max_count = frame->type == RILLIGHT_CORE_VIDEO_RGBA
                             ? kMaxVideoFrames : kMaxAudioFrames;
  const auto max_bytes = frame->type == RILLIGHT_CORE_VIDEO_RGBA
                             ? kMaxVideoBytes : kMaxAudioBytes;
  core->wake.wait(lock, [&] {
    return core->stop || core->timeline != timeline ||
           (queue.size() < max_count && bytes + frame->data_size <= max_bytes);
  });
  if (core->stop || core->timeline != timeline) {
    lock.unlock();
    rillight_core_release_frame(frame);
    return;
  }
  bytes += frame->data_size;
  queue.push_back(frame);
  if (frame->type == RILLIGHT_CORE_VIDEO_RGBA) core->first_video = true;
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
}

int drain_audio_filter(RillightCoreImpl *core, AudioFilter *filter,
                       int video_index, uint64_t session, uint64_t timeline) {
  if (!filter->graph) return 0;
  AVFrame *filtered = av_frame_alloc();
  if (!filtered) return AVERROR(ENOMEM);
  int result = 0;
  while (!core->stop) {
    result = av_buffersink_get_frame(filter->sink, filtered);
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
    enqueue(core, output, video_index, timeline);
    std::lock_guard lock(core->mutex);
    if (core->timeline != timeline) break;
  }
  av_frame_free(&filtered);
  return result;
}

int decode_packet(RillightCoreImpl *core, AVFormatContext *format,
                  Decoder &decoder, const AVPacket *packet, int video_index,
                  SwsContext **scale, AudioFilter *audio_filter,
                  std::vector<SubtitleCue> *cues, AssRenderer *ass,
                  double speed,
                  uint64_t session, uint64_t timeline) {
  if (!decoder.context) return 0;
  int result = avcodec_send_packet(decoder.context, packet);
  if (result < 0) return result;
  AVFrame *decoded = av_frame_alloc();
  if (!decoded) return AVERROR(ENOMEM);
  while (!core->stop) {
    result = avcodec_receive_frame(decoder.context, decoded);
    if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) break;
    if (result < 0) break;
    const int64_t pts = frame_time(decoded, format->streams[decoder.stream]);
    if (decoder.stream == video_index) {
      const AVFrame *picture = decoded;
      AVFrame *downloaded = nullptr;
      bool decoded_with_hardware = false;
      // A MediaCodec CPU frame does not identify the selected codec as hardware.
      if (decoder.hardware != RILLIGHT_CORE_HW_NONE && decoder.hw_format &&
          decoded->format == *decoder.hw_format) {
        downloaded = av_frame_alloc();
        if (!downloaded) { result = AVERROR(ENOMEM); break; }
        result = av_hwframe_transfer_data(downloaded, decoded, 0);
        if (result >= 0) result = av_frame_copy_props(downloaded, decoded);
        if (result < 0) {
          av_frame_free(&downloaded);
          break;
        }
        picture = downloaded;
        decoded_with_hardware = true;
      }
      auto *output = convert_video(picture, pts, session, timeline,
                                   format->streams[decoder.stream], scale);
      av_frame_free(&downloaded);
      av_frame_unref(decoded);
      if (!output) { result = AVERROR(EINVAL); break; }
      if (decoded_with_hardware) {
        std::lock_guard lock(core->mutex);
        for (auto &track : core->tracks) {
          if (track.stream_index == decoder.stream)
            track.actual_hardware = decoder.hardware;
        }
      }
      blend_subtitles(output, *cues);
      blend_ass(output, ass);
      if (pts >= 0)
        cues->erase(std::remove_if(cues->begin(), cues->end(),
                                   [pts](const SubtitleCue &cue) {
                                     return cue.end_us < pts;
                                   }), cues->end());
      enqueue(core, output, video_index, timeline);
    } else {
      result = prepare_audio_filter(audio_filter, decoded, speed, pts);
      decoded->pts = pts < 0 ? AV_NOPTS_VALUE :
          av_rescale_q(pts, AVRational{1, 1000000},
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

void run(RillightCoreImpl *core, uint64_t session) {
  AVFormatContext *format = avformat_alloc_context();
  Source *main_source = nullptr;
  Decoder video, audio, subtitle;
  SwsContext *scale = nullptr;
  AudioFilter audio_filter;
  std::vector<SubtitleCue> subtitle_cues;
  AssRenderer ass;
  int result = AVERROR(ENOMEM);
  bool ended = false;
  if (!format) goto finish;
  core->active_read_timeline = core->timeline_signal.load();
  format->opaque = core;
  format->interrupt_callback = AVIOInterruptCB{interrupt_read, core};
  format->io_open = nested_open;
  format->io_close2 = nested_close;
  main_source = open_source(core, core->url.c_str(), AVIO_FLAG_READ);
  if (!main_source) { result = AVERROR(EACCES); goto finish; }
  format->pb = main_source->avio;
  format->flags |= AVFMT_FLAG_CUSTOM_IO;
  result = avformat_open_input(&format, core->url.c_str(), nullptr, nullptr);
  if (result < 0) goto finish;
  result = avformat_find_stream_info(format, nullptr);
  if (result < 0) goto finish;
  {
    const int vi = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1,
                                       nullptr, 0);
    const int ai = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1,
                                       nullptr, 0);
    video = make_decoder(format, vi, core->hardware_preference,
                         core->allow_software_fallback);
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
    core->audio_index = audio.stream;
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
      std::lock_guard lock(core->mutex);
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
      if (video.context) avcodec_flush_buffers(video.context);
      if (audio.context) avcodec_flush_buffers(audio.context);
      if (subtitle.context) avcodec_flush_buffers(subtitle.context);
      close_audio_filter(&audio_filter);
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
        core->error = 0;
      } else {
        avcodec_free_context(&replacement.context);
        std::lock_guard lock(core->mutex);
        core->error = AVERROR_DECODER_NOT_FOUND;
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
        subtitle_cues.clear();
        close_ass(&ass);
#if RILLIGHT_HAVE_LIBASS
        if (ass_selected) ass = replacement_ass;
#endif
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
    result = av_read_frame(format, packet);
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
        if (core->state == RILLIGHT_CORE_PLAYING)
          core->state = RILLIGHT_CORE_BUFFERING;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
      continue;
    }
    if (result == AVERROR_EOF) {
      av_packet_free(&packet);
      {
        std::lock_guard lock(core->mutex);
        if (core->timeline != timeline) continue;
        core->input_exhausted = true;
      }
      result = decode_packet(core, format, video, nullptr, video.stream,
                             &scale, &audio_filter, &subtitle_cues, &ass,
                             core->speed, session,
                             timeline);
      if (result < 0) break;
      result = decode_packet(core, format, audio, nullptr, video.stream,
                             &scale, &audio_filter, &subtitle_cues, &ass,
                             core->speed, session,
                             timeline);
      if (result < 0) break;
      if (audio_filter.graph) {
        result = av_buffersrc_add_frame_flags(audio_filter.source, nullptr, 0);
        if (result < 0) break;
        result = drain_audio_filter(core, &audio_filter, video.stream, session,
                                    timeline);
        if (result < 0) break;
      }
      std::unique_lock lock(core->mutex);
      if (core->timeline != timeline) continue;
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
      result = decode_packet(core, format, video, packet, video.stream,
                             &scale, &audio_filter, &subtitle_cues, &ass,
                             core->speed, session,
                             timeline);
    else if (packet->stream_index == audio.stream)
      result = decode_packet(core, format, audio, packet, video.stream,
                             &scale, &audio_filter, &subtitle_cues, &ass,
                             core->speed, session,
                             timeline);
    else if (packet->stream_index == subtitle.stream) {
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
    }
    else
      result = 0;
    av_packet_free(&packet);
    if (result < 0) break;
  }
finish:
  close_ass(&ass);
  close_audio_filter(&audio_filter);
  sws_freeContext(scale);
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
  }
  delete core;
}

int rillight_core_open(RillightCore *pointer, const char *url,
                       uint64_t operation_id) {
  if (!pointer || !url || !*url) return -1;
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
    core->stop = false;
    core->media_io_active = false;
    ++core->session;
    ++core->timeline;
    core->timeline_signal = core->timeline;
    core->url = url;
    core->video_index = core->audio_index = core->subtitle_index = -1;
    core->duration = -1;
    core->base_position = 0;
    core->base_time = Clock::now();
    core->seek_target = -1;
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
  if (core->state == RILLIGHT_CORE_PLAYING && !playing &&
      !core->audio_clock_active) {
    core->base_position += std::chrono::duration_cast<std::chrono::microseconds>(
                               Clock::now() - core->base_time).count() *
                           core->speed;
  }
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
  // The worker cannot start a new-timeline read until this callback returns.
  if (core->media_io_active)
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
      core->state == RILLIGHT_CORE_FAILED ||
      !accept_operation(core, operation_id)) return -1;
  if (core->state == RILLIGHT_CORE_PLAYING && !core->audio_clock_active)
    core->base_position += static_cast<int64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            Clock::now() - core->base_time).count() * core->speed);
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

int rillight_core_select_subtitle(RillightCore *pointer, int stream_index,
                                   uint64_t operation_id) {
  if (!pointer || stream_index < -1) return -1;
  auto *core = impl(pointer);
  std::unique_lock lock(core->mutex);
  if (core->state == RILLIGHT_CORE_IDLE ||
      core->state == RILLIGHT_CORE_OPENING ||
      core->state == RILLIGHT_CORE_ENDED ||
      core->state == RILLIGHT_CORE_FAILED ||
      core->input_exhausted) return -1;
  if (stream_index != -1 &&
      std::none_of(core->tracks.begin(), core->tracks.end(),
                   [stream_index](const RillightCoreTrack &track) {
                     return track.type == RILLIGHT_CORE_TRACK_SUBTITLE &&
                            track.stream_index == stream_index;
                   })) return -1;
  if (!accept_operation(core, operation_id)) return -1;
  if (core->state == RILLIGHT_CORE_PLAYING && !core->audio_clock_active)
    core->base_position += static_cast<int64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            Clock::now() - core->base_time).count() * core->speed);
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
  if (!pointer || !std::isfinite(speed) || speed < 0.5 || speed > 2.0)
    return -1;
  auto *core = impl(pointer);
  std::unique_lock lock(core->mutex);
  if (core->state == RILLIGHT_CORE_IDLE ||
      core->state == RILLIGHT_CORE_OPENING ||
      core->state == RILLIGHT_CORE_ENDED ||
      core->state == RILLIGHT_CORE_FAILED ||
      !accept_operation(core, operation_id)) return -1;
  if (core->state == RILLIGHT_CORE_PLAYING && !core->audio_clock_active)
    core->base_position += static_cast<int64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            Clock::now() - core->base_time).count() * core->speed);
  core->requested_speed = speed;
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
  const auto now = Clock::now();
  int64_t current_position = core->base_position;
  if (!core->audio_clock_active && core->state == RILLIGHT_CORE_PLAYING)
    current_position += static_cast<int64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            now - core->base_time).count() * core->speed);
  const int64_t reported_position =
      std::max<int64_t>(0, queued_end_pts_us - remaining_media_delay_us);
  if (core->audio_clock_handed_off && reported_position < current_position)
    return -1;
  core->audio_clock_active = true;
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
  snapshot->position_us = core->base_position;
  if (!core->audio_clock_active && core->state == RILLIGHT_CORE_PLAYING)
    snapshot->position_us += std::chrono::duration_cast<std::chrono::microseconds>(
                                 Clock::now() - core->base_time).count() *
                             core->speed;
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

RillightCoreFrame *rillight_core_take_frame(RillightCore *pointer, int type) {
  if (!pointer) return nullptr;
  auto *core = impl(pointer);
  std::lock_guard lock(core->mutex);
  if (type != RILLIGHT_CORE_VIDEO_RGBA && type != RILLIGHT_CORE_AUDIO_S16)
    return nullptr;
  auto &queue = type == RILLIGHT_CORE_VIDEO_RGBA ? core->video : core->audio;
  auto &bytes = type == RILLIGHT_CORE_VIDEO_RGBA ? core->video_bytes : core->audio_bytes;
  if (queue.empty()) return nullptr;
  if (type == RILLIGHT_CORE_VIDEO_RGBA && queue.front()->pts_us >= 0) {
    int64_t clock_us = core->base_position;
    if (!core->audio_clock_active && core->state == RILLIGHT_CORE_PLAYING)
      clock_us += std::chrono::duration_cast<std::chrono::microseconds>(
                      Clock::now() - core->base_time).count() * core->speed;
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
  auto *frame = queue.front();
  queue.pop_front();
  bytes -= frame->data_size;
  if (type == RILLIGHT_CORE_VIDEO_RGBA)
    core->paused_video_frame_emitted = true;
  core->wake.notify_all();
  return frame;
}

void rillight_core_release_frame(RillightCoreFrame *frame) {
  if (!frame) return;
  delete[] frame->data;
  delete frame;
}
}  // extern "C"
