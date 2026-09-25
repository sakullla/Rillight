#include "../core/rillight_core.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libavutil/display.h>
}

namespace {
struct Blocking {
  std::mutex mutex;
  std::condition_variable wake;
  bool entered = false;
  bool cancelled = false;
};

struct Bytes {
  std::vector<uint8_t> data;
  size_t offset = 0;
  bool fail_read = false;
  Blocking *block = nullptr;
  int slow_progress_reads = 0;
  bool eagain_after_progress = false;
  size_t stall_at_offset = 0;
};

struct Media {
  Bytes video;
  Bytes srt_video;
  Bytes vtt_video;
  Bytes external;
  Bytes external_srt;
  Bytes external_vtt;
  Bytes invalid_srt;
  Bytes invalid;
  Bytes read_failure;
  Bytes blocked;
  Bytes slow;
  Blocking blocking;
};

constexpr const char *kAssHeader =
    "[Script Info]\nScriptType: v4.00+\nPlayResX: 320\nPlayResY: 180\n"
    "[V4+ Styles]\n"
    "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, "
    "OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, "
    "ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
    "Alignment, MarginL, MarginR, MarginV, Encoding\n"
    "Style: Default,DejaVu Sans,28,&H00FFFFFF,&H000000FF,&H00000000,"
    "&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,18,1\n"
    "[Events]\n"
    "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, "
    "Effect, Text\n";

Bytes make_external_ass() {
  std::string script(kAssHeader);
  const auto primary = script.find("&H00FFFFFF");
  assert(primary != std::string::npos);
  script.replace(primary, std::strlen("&H00FFFFFF"), "&H00FF0000");
  script += "Dialogue: 0,0:00:00.00,0:00:04.00,Default,,0,0,0,,EXTERNAL BLUE\n";
  Bytes bytes;
  bytes.data.assign(script.begin(), script.end());
  return bytes;
}

Bytes text_bytes(const char *text) {
  Bytes bytes;
  bytes.data.assign(text, text + std::strlen(text));
  return bytes;
}

int write_video_packets(AVFormatContext *format, AVCodecContext *encoder,
                        AVStream *stream, AVFrame *frame) {
  int result = avcodec_send_frame(encoder, frame);
  if (result < 0) return result;
  AVPacket *packet = av_packet_alloc();
  if (!packet) return AVERROR(ENOMEM);
  while ((result = avcodec_receive_packet(encoder, packet)) >= 0) {
    av_packet_rescale_ts(packet, encoder->time_base, stream->time_base);
    packet->stream_index = stream->index;
    result = av_interleaved_write_frame(format, packet);
    av_packet_unref(packet);
    if (result < 0) break;
  }
  av_packet_free(&packet);
  return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}

Bytes make_ass_video(AVCodecID subtitle_codec = AV_CODEC_ID_ASS) {
  AVFormatContext *format = nullptr;
  assert(avformat_alloc_output_context2(&format, nullptr, "matroska", nullptr) == 0);
  assert(avio_open_dyn_buf(&format->pb) >= 0);
  const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_MPEG4);
  assert(codec);
  AVCodecContext *encoder = avcodec_alloc_context3(codec);
  assert(encoder);
  encoder->width = 320;
  encoder->height = 180;
  encoder->pix_fmt = AV_PIX_FMT_YUV420P;
  encoder->time_base = AVRational{1, 10};
  encoder->framerate = AVRational{10, 1};
  encoder->bit_rate = 300000;
  encoder->sample_aspect_ratio = AVRational{2, 1};
  encoder->color_range = AVCOL_RANGE_MPEG;
  encoder->colorspace = AVCOL_SPC_BT709;
  encoder->color_primaries = AVCOL_PRI_BT709;
  encoder->color_trc = AVCOL_TRC_BT709;
  assert(avcodec_open2(encoder, codec, nullptr) == 0);
  AVStream *video = avformat_new_stream(format, nullptr);
  assert(video);
  video->time_base = encoder->time_base;
  assert(avcodec_parameters_from_context(video->codecpar, encoder) == 0);
  video->sample_aspect_ratio = AVRational{2, 1};
  auto *display = av_packet_side_data_new(
      &video->codecpar->coded_side_data,
      &video->codecpar->nb_coded_side_data,
      AV_PKT_DATA_DISPLAYMATRIX, 9 * sizeof(int32_t), 0);
  assert(display);
  av_display_rotation_set(reinterpret_cast<int32_t *>(display->data), 90);

  AVStream *subtitle = avformat_new_stream(format, nullptr);
  assert(subtitle);
  subtitle->time_base = AVRational{1, 1000};
  subtitle->codecpar->codec_type = AVMEDIA_TYPE_SUBTITLE;
  subtitle->codecpar->codec_id = subtitle_codec;
  if (subtitle_codec == AV_CODEC_ID_ASS) {
    const size_t header_size = std::strlen(kAssHeader);
    subtitle->codecpar->extradata = static_cast<uint8_t *>(
        av_mallocz(header_size + AV_INPUT_BUFFER_PADDING_SIZE));
    assert(subtitle->codecpar->extradata);
    std::memcpy(subtitle->codecpar->extradata, kAssHeader, header_size);
    subtitle->codecpar->extradata_size = static_cast<int>(header_size);
  }
  assert(avformat_write_header(format, nullptr) == 0);

  const char *event = subtitle_codec == AV_CODEC_ID_ASS ?
      "0,0,Default,,0,0,0,,VISIBLE SUBTITLE" : "VISIBLE TEXT";
  AVPacket *subtitle_packet = av_packet_alloc();
  assert(subtitle_packet);
  assert(av_new_packet(subtitle_packet, static_cast<int>(std::strlen(event))) == 0);
  std::memcpy(subtitle_packet->data, event, std::strlen(event));
  subtitle_packet->stream_index = subtitle->index;
  subtitle_packet->pts = 0;
  subtitle_packet->dts = 0;
  subtitle_packet->duration = 4000;
  assert(av_interleaved_write_frame(format, subtitle_packet) == 0);
  av_packet_free(&subtitle_packet);

  AVFrame *frame = av_frame_alloc();
  assert(frame);
  frame->format = encoder->pix_fmt;
  frame->width = encoder->width;
  frame->height = encoder->height;
  assert(av_frame_get_buffer(frame, 32) == 0);
  for (int index = 0; index < 30; ++index) {
    assert(av_frame_make_writable(frame) == 0);
    for (int row = 0; row < frame->height; ++row)
      std::memset(frame->data[0] + row * frame->linesize[0], 16, frame->width);
    for (int row = 0; row < frame->height / 2; ++row) {
      std::memset(frame->data[1] + row * frame->linesize[1], 128,
                  frame->width / 2);
      std::memset(frame->data[2] + row * frame->linesize[2], 128,
                  frame->width / 2);
    }
    frame->pts = index;
    assert(write_video_packets(format, encoder, video, frame) == 0);
  }
  assert(write_video_packets(format, encoder, video, nullptr) == 0);
  assert(av_write_trailer(format) == 0);
  av_frame_free(&frame);
  avcodec_free_context(&encoder);
  uint8_t *buffer = nullptr;
  const int length = avio_close_dyn_buf(format->pb, &buffer);
  assert(length > 0 && buffer);
  Bytes bytes;
  bytes.data.assign(buffer, buffer + length);
  av_free(buffer);
  avformat_free_context(format);
  return bytes;
}

void *open(void *opaque, const char *url, int) {
  auto *media = static_cast<Media *>(opaque);
  if (std::strcmp(url, "synthetic.mkv") == 0) return new Bytes(media->video);
  if (std::strcmp(url, "synthetic-srt.mkv") == 0)
    return new Bytes(media->srt_video);
  if (std::strcmp(url, "synthetic-vtt.mkv") == 0)
    return new Bytes(media->vtt_video);
  if (std::strcmp(url, "external.ass") == 0)
    return new Bytes(media->external);
  if (std::strcmp(url, "external.srt") == 0)
    return new Bytes(media->external_srt);
  if (std::strcmp(url, "external.vtt") == 0)
    return new Bytes(media->external_vtt);
  if (std::strcmp(url, "invalid.srt") == 0)
    return new Bytes(media->invalid_srt);
  if (std::strcmp(url, "invalid.ass") == 0)
    return new Bytes(media->invalid);
  if (std::strcmp(url, "read-failure.ass") == 0)
    return new Bytes(media->read_failure);
  if (std::strcmp(url, "blocked.ass") == 0)
    return new Bytes(media->blocked);
  if (std::strcmp(url, "slow.ass") == 0)
    return new Bytes(media->slow);
  return nullptr;
}

int read(void *, void *handle, uint8_t *data, int size) {
  auto *bytes = static_cast<Bytes *>(handle);
  if (bytes->block) {
    std::unique_lock lock(bytes->block->mutex);
    bytes->block->entered = true;
    bytes->block->wake.notify_all();
    bytes->block->wake.wait(lock, [&] { return bytes->block->cancelled; });
    return -5;
  }
  if (bytes->fail_read) return -5;
  if (bytes->stall_at_offset &&
      bytes->offset >= bytes->stall_at_offset) return -11;
  if (bytes->slow_progress_reads > 0) {
    std::this_thread::sleep_for(std::chrono::milliseconds(550));
    --bytes->slow_progress_reads;
    size = std::min(size, 32);
  } else if (bytes->eagain_after_progress) {
    bytes->eagain_after_progress = false;
    return -11;
  }
  if (bytes->stall_at_offset)
    size = std::min(size, 1024);
  size_t count = std::min(static_cast<size_t>(size),
                          bytes->data.size() - bytes->offset);
  if (bytes->stall_at_offset)
    count = std::min(count, bytes->stall_at_offset - bytes->offset);
  if (!count) return 0;
  std::memcpy(data, bytes->data.data() + bytes->offset, count);
  bytes->offset += count;
  return static_cast<int>(count);
}

int64_t seek(void *, void *handle, int64_t offset, int whence) {
  auto *bytes = static_cast<Bytes *>(handle);
  if (whence == AVSEEK_SIZE) return static_cast<int64_t>(bytes->data.size());
  int64_t base = 0;
  if (whence == SEEK_CUR) base = static_cast<int64_t>(bytes->offset);
  if (whence == SEEK_END) base = static_cast<int64_t>(bytes->data.size());
  const int64_t target = base + offset;
  if (target < 0 || target > static_cast<int64_t>(bytes->data.size())) return -1;
  bytes->offset = static_cast<size_t>(target);
  return target;
}

void close(void *, void *handle) { delete static_cast<Bytes *>(handle); }

void cancel(void *opaque) {
  auto *blocking = &static_cast<Media *>(opaque)->blocking;
  {
    std::lock_guard lock(blocking->mutex);
    blocking->cancelled = true;
  }
  blocking->wake.notify_all();
}
void cancel_media_read(void *) {}

RillightCoreSnapshot snapshot(RillightCore *core) {
  RillightCoreSnapshot state{};
  state.struct_size = sizeof(state);
  assert(rillight_core_snapshot(core, &state) == 0);
  return state;
}

template <typename Predicate>
bool wait_for(RillightCore *core, Predicate predicate,
              bool drain_video = false, int timeout_seconds = 5) {
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(timeout_seconds);
  while (std::chrono::steady_clock::now() < deadline) {
    if (predicate(snapshot(core))) return true;
    if (drain_video) {
      auto *frame = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
      rillight_core_release_frame(frame);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return false;
}
}  // namespace

int main() {
  assert(rillight_core_abi_version() == 5);
  Media media{};
  media.video = make_ass_video();
  media.srt_video = make_ass_video(AV_CODEC_ID_SUBRIP);
  media.vtt_video = make_ass_video(AV_CODEC_ID_WEBVTT);
  media.srt_video.stall_at_offset = media.srt_video.data.size() - 1;
  media.vtt_video.stall_at_offset = media.vtt_video.data.size() - 1;
  media.external = make_external_ass();
  media.external_srt = text_bytes(
      "1\n00:00:01,000 --> 00:00:02,000\nEXTERNAL SRT\n\n");
  media.external_vtt = text_bytes(
      "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nEXTERNAL WEBVTT\n\n");
  media.invalid_srt = text_bytes("not a timed subtitle\n");
  media.invalid.data = {'n', 'o', 't', ' ', 'A', 'S', 'S'};
  media.read_failure.fail_read = true;
  media.blocked.block = &media.blocking;
  media.slow = make_external_ass();
  media.slow.slow_progress_reads = 10;
  media.slow.eagain_after_progress = true;
  RillightCoreIo io{&media, open, read, seek, close, cancel,
                    cancel_media_read};
  RillightCore *core = rillight_core_create(&io);
  assert(core && rillight_core_open(core, "synthetic.mkv", 1) == 0);
  assert(wait_for(core, [](const auto &state) {
    return state.first_video_frame_ready && state.subtitle_stream_index >= 0;
  }));
  assert(rillight_core_track_count(core) == 2);
  const auto initial = snapshot(core);
  bool embedded_rendered = false;
  bool display_metadata_seen = false;
  bool display_metadata_diagnosed = false;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(5);
  while (std::chrono::steady_clock::now() < deadline && !embedded_rendered) {
    RillightCoreFrame *frame =
        rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
    if (!frame) {
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
      continue;
    }
    if (frame->pts_us >= 100000 && frame->pts_us <= 2000000) {
      const double rotation = frame->has_display_matrix ?
          av_display_rotation_get(frame->display_matrix) : NAN;
      // Matroska's display-matrix convention reports this muxed 90-degree
      // fixture as -90 degrees after FFmpeg demux. Preserve that signed value.
      const bool metadata_matches = frame->struct_size == sizeof(*frame) &&
          frame->sar_num == 2 && frame->sar_den == 1 &&
          frame->has_display_matrix &&
          std::isfinite(rotation) && std::abs(rotation + 90.0) < 1.0 &&
          frame->source_color_range == AVCOL_RANGE_MPEG &&
          frame->source_color_space == AVCOL_SPC_BT709 &&
          frame->source_color_primaries == AVCOL_PRI_BT709 &&
          frame->source_color_transfer == AVCOL_TRC_BT709;
      display_metadata_seen |= metadata_matches;
      if (!metadata_matches && !display_metadata_diagnosed) {
        std::fprintf(stderr,
            "decoded frame metadata: ABI=%u size=%u SAR=%d/%d matrix=%d "
            "rotation=%.1f range=%d space=%d primaries=%d transfer=%d "
            "(expected ABI=5 size=%zu SAR=2/1 rotation=-90 range=%d "
            "space=%d primaries=%d transfer=%d)\n",
            rillight_core_abi_version(), frame->struct_size,
            frame->sar_num, frame->sar_den, frame->has_display_matrix,
            rotation, frame->source_color_range, frame->source_color_space,
            frame->source_color_primaries, frame->source_color_transfer,
            sizeof(*frame), AVCOL_RANGE_MPEG, AVCOL_SPC_BT709,
            AVCOL_PRI_BT709, AVCOL_TRC_BT709);
        display_metadata_diagnosed = true;
      }
      for (int row = frame->height / 2; row < frame->height; ++row) {
        for (int column = 0; column < frame->width; ++column) {
          const uint8_t *pixel = frame->data +
              static_cast<size_t>(row) * frame->stride + column * 4;
          embedded_rendered |= pixel[0] > 100 && pixel[1] > 100 &&
                               pixel[2] > 100;
        }
      }
    }
    rillight_core_release_frame(frame);
  }
  assert(embedded_rendered);
  assert(display_metadata_seen);

  assert(rillight_core_add_external_subtitle(
             core, "read-failure.ass", 2) == 0);
  assert(wait_for(core, [](const auto &state) {
    return !state.external_subtitle_pending && state.ffmpeg_error < 0;
  }, true));
  assert(rillight_core_track_count(core) == 2);
  assert(snapshot(core).subtitle_stream_index == initial.subtitle_stream_index &&
         snapshot(core).timeline_version == initial.timeline_version &&
         snapshot(core).state != RILLIGHT_CORE_FAILED);

  assert(rillight_core_add_external_subtitle(core, "invalid.ass", 3) == 0);
  assert(wait_for(core, [](const auto &state) {
    return !state.external_subtitle_pending && state.ffmpeg_error < 0;
  }, true));
  assert(rillight_core_track_count(core) == 2);
  assert(snapshot(core).subtitle_stream_index == initial.subtitle_stream_index &&
         snapshot(core).timeline_version == initial.timeline_version &&
         snapshot(core).state != RILLIGHT_CORE_FAILED);

  assert(rillight_core_add_external_subtitle(core, "external.ass", 4) == 0);
  assert(wait_for(core, [](const auto &state) {
    return !state.external_subtitle_pending && state.ffmpeg_error == 0;
  }, true));
  assert(rillight_core_track_count(core) == 3);
  RillightCoreTrack external{};
  external.struct_size = sizeof(external);
  assert(rillight_core_get_track(core, 2, &external) == 0);
  assert(external.type == RILLIGHT_CORE_TRACK_SUBTITLE &&
         external.is_external == 1 && external.stream_index >= 1000000);
  assert(snapshot(core).subtitle_stream_index == initial.subtitle_stream_index &&
         snapshot(core).timeline_version == initial.timeline_version);

  assert(rillight_core_select_subtitle(core, external.stream_index + 1, 5) != 0);
  assert(snapshot(core).subtitle_stream_index == initial.subtitle_stream_index &&
         snapshot(core).timeline_version == initial.timeline_version);
  assert(rillight_core_select_subtitle(core, external.stream_index, 6) == 0);
  assert(wait_for(core, [external](const auto &state) {
    return state.subtitle_stream_index == external.stream_index &&
           state.first_video_frame_ready;
  }));
  assert(snapshot(core).timeline_version > initial.timeline_version);
  bool external_rendered = false;
  int frames = 0;
  const auto external_deadline = std::chrono::steady_clock::now() +
                                 std::chrono::seconds(6);
  while (std::chrono::steady_clock::now() < external_deadline &&
         !external_rendered) {
    RillightCoreFrame *frame =
        rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
    if (!frame) {
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
      continue;
    }
    ++frames;
    if (frame->pts_us >= 100000 && frame->pts_us <= 3000000) {
      for (int row = frame->height / 2; row < frame->height; ++row) {
        for (int column = 0; column < frame->width; ++column) {
          const uint8_t *pixel = frame->data +
              static_cast<size_t>(row) * frame->stride + column * 4;
          external_rendered |= pixel[2] > 100 && pixel[0] < 60 &&
                               pixel[1] < 60;
        }
      }
    }
    rillight_core_release_frame(frame);
  }
  assert(frames > 0 && external_rendered);

  assert(rillight_core_open(core, "synthetic.mkv", 7) == 0);
  assert(wait_for(core, [](const auto &state) {
    return state.session_id == 2 && state.first_video_frame_ready;
  }));
  assert(rillight_core_track_count(core) == 2);
  assert(rillight_core_select_subtitle(core, external.stream_index, 8) != 0);
  {
    std::lock_guard lock(media.blocking.mutex);
    media.blocking.entered = false;
    media.blocking.cancelled = false;
  }
  assert(rillight_core_add_external_subtitle(core, "blocked.ass", 9) == 0);
  {
    std::unique_lock lock(media.blocking.mutex);
    assert(media.blocking.wake.wait_for(lock, std::chrono::seconds(2), [&] {
      return media.blocking.entered;
    }));
  }
  const auto control_start = std::chrono::steady_clock::now();
  assert(rillight_core_set_playing(core, 0, 10) == 0);
  assert(std::chrono::steady_clock::now() - control_start <
         std::chrono::milliseconds(500));
  assert(snapshot(core).state == RILLIGHT_CORE_PAUSED);
  const auto timeline_before_seek = snapshot(core).timeline_version;
  const auto seek_start = std::chrono::steady_clock::now();
  assert(rillight_core_seek(core, 0, 11) == 0);
  assert(std::chrono::steady_clock::now() - seek_start <
         std::chrono::milliseconds(500));
  assert(wait_for(core, [timeline_before_seek](const auto &state) {
    return state.timeline_version > timeline_before_seek &&
           state.first_video_frame_ready &&
           state.state != RILLIGHT_CORE_FAILED;
  }));
  assert(snapshot(core).external_subtitle_pending);
  assert(rillight_core_set_playing(core, 1, 12) == 0);
  bool frame_while_blocked = false;
  const auto frame_deadline = std::chrono::steady_clock::now() +
                              std::chrono::seconds(2);
  while (std::chrono::steady_clock::now() < frame_deadline &&
         !frame_while_blocked) {
    auto *frame = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
    frame_while_blocked = frame != nullptr;
    rillight_core_release_frame(frame);
    if (!frame_while_blocked)
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  assert(frame_while_blocked && snapshot(core).external_subtitle_pending);
  const auto close_start = std::chrono::steady_clock::now();
  rillight_core_destroy(core);
  assert(std::chrono::steady_clock::now() - close_start <
         std::chrono::seconds(2));
  core = rillight_core_create(&io);
  assert(core && rillight_core_open(core, "synthetic.mkv", 1) == 0);
  assert(wait_for(core, [](const auto &state) {
    return state.first_video_frame_ready;
  }));
  assert(rillight_core_add_external_subtitle(core, "slow.ass", 2) == 0);
  assert(wait_for(core, [](const auto &state) {
    return !state.external_subtitle_pending && state.ffmpeg_error == 0;
  }, false, 9));
  assert(rillight_core_track_count(core) == 3);
  rillight_core_destroy(core);
  for (const char *url : {"synthetic-srt.mkv", "synthetic-vtt.mkv"}) {
    core = rillight_core_create(&io);
    assert(core && rillight_core_open(core, url, 1) == 0);
    assert(wait_for(core, [](const auto &state) {
      return state.first_video_frame_ready &&
             state.subtitle_stream_index >= 0 &&
             state.state != RILLIGHT_CORE_FAILED;
    }));
    assert(rillight_core_track_count(core) == 2);
    RillightCoreTrack text_track{};
    text_track.struct_size = sizeof(text_track);
    assert(rillight_core_get_track(core, 1, &text_track) == 0);
    assert(text_track.type == RILLIGHT_CORE_TRACK_SUBTITLE);
    assert(rillight_core_select_subtitle(core, -1, 2) == 0);
    assert(wait_for(core, [](const auto &state) {
      return state.subtitle_stream_index == -1 &&
             state.first_video_frame_ready && state.state != RILLIGHT_CORE_FAILED;
    }));
    assert(rillight_core_select_subtitle(core, text_track.stream_index, 3) == 0);
    assert(wait_for(core, [text_track](const auto &state) {
      return state.subtitle_stream_index == text_track.stream_index &&
             state.first_video_frame_ready && state.state != RILLIGHT_CORE_FAILED;
    }));
    bool text_rendered = false;
    const auto text_deadline = std::chrono::steady_clock::now() +
                               std::chrono::seconds(5);
    while (std::chrono::steady_clock::now() < text_deadline &&
           !text_rendered) {
      auto *text_frame = rillight_core_take_frame(core,
                                                  RILLIGHT_CORE_VIDEO_RGBA);
      if (!text_frame) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        continue;
      }
      if (text_frame->pts_us >= 100000 && text_frame->pts_us <= 2000000) {
        for (int row = text_frame->height / 2; row < text_frame->height;
             ++row) {
          for (int column = 0; column < text_frame->width; ++column) {
            const uint8_t *pixel = text_frame->data +
                static_cast<size_t>(row) * text_frame->stride + column * 4;
            text_rendered |= pixel[0] > 100 && pixel[1] > 100 &&
                             pixel[2] > 100;
          }
        }
      }
      rillight_core_release_frame(text_frame);
    }
    assert(text_rendered);
    rillight_core_destroy(core);
  }
  for (const auto &external_text : {
           std::pair<const char *, AVCodecID>{"external.srt", AV_CODEC_ID_SUBRIP},
           {"external.vtt", AV_CODEC_ID_WEBVTT}}) {
    core = rillight_core_create(&io);
    assert(core && rillight_core_open(core, "synthetic.mkv", 1) == 0);
    assert(wait_for(core, [](const auto &state) {
      return state.first_video_frame_ready && state.state != RILLIGHT_CORE_FAILED;
    }));
    const auto before_external = snapshot(core);
    assert(rillight_core_add_external_subtitle(core, "invalid.srt", 2) == 0);
    assert(wait_for(core, [](const auto &state) {
      return !state.external_subtitle_pending && state.ffmpeg_error < 0;
    }));
    assert(rillight_core_track_count(core) == 2);
    assert(snapshot(core).subtitle_stream_index ==
               before_external.subtitle_stream_index &&
           snapshot(core).timeline_version == before_external.timeline_version);
    assert(rillight_core_add_external_subtitle(core, external_text.first, 3) == 0);
    assert(wait_for(core, [](const auto &state) {
      return !state.external_subtitle_pending && state.ffmpeg_error == 0;
    }));
    assert(rillight_core_track_count(core) == 3);
    RillightCoreTrack added{};
    added.struct_size = sizeof(added);
    assert(rillight_core_get_track(core, 2, &added) == 0);
    assert(added.type == RILLIGHT_CORE_TRACK_SUBTITLE &&
           added.is_external == 1 && added.codec_id == external_text.second);
    assert(snapshot(core).subtitle_stream_index ==
           before_external.subtitle_stream_index);
    assert(rillight_core_select_subtitle(core, added.stream_index, 4) == 0);
    assert(wait_for(core, [added](const auto &state) {
      return state.subtitle_stream_index == added.stream_index &&
             state.first_video_frame_ready && state.state != RILLIGHT_CORE_FAILED;
    }));
    assert(rillight_core_seek(core, 0, 5) == 0);
    assert(wait_for(core, [](const auto &state) {
      return state.first_video_frame_ready && state.state != RILLIGHT_CORE_FAILED;
    }));
    assert(rillight_core_set_playing(core, 1, 6) == 0);
    bool early_blank = false;
    bool timed_text_visible = false;
    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::seconds(5);
    while (std::chrono::steady_clock::now() < deadline &&
           !(early_blank && timed_text_visible)) {
      auto *video_frame = rillight_core_take_frame(core,
                                                   RILLIGHT_CORE_VIDEO_RGBA);
      if (!video_frame) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        continue;
      }
      bool bright = false;
      for (int row = video_frame->height / 2; row < video_frame->height;
           ++row) {
        for (int column = 0; column < video_frame->width; ++column) {
          const uint8_t *pixel = video_frame->data +
              static_cast<size_t>(row) * video_frame->stride + column * 4;
          bright |= pixel[0] > 100 && pixel[1] > 100 && pixel[2] > 100;
        }
      }
      if (video_frame->pts_us <= 400000) early_blank |= !bright;
      if (video_frame->pts_us >= 1100000 &&
          video_frame->pts_us <= 1900000) timed_text_visible |= bright;
      rillight_core_release_frame(video_frame);
    }
    assert(early_blank && timed_text_visible);
    rillight_core_destroy(core);
  }
  std::printf("Embedded and external ASS subtitle composition verified (%d "
              "external frames)\n", frames);
  return 0;
}
