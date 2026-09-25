#include "../core/rillight_core.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
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
};

struct Media {
  Bytes video;
  Bytes external;
  Bytes invalid;
  Bytes read_failure;
  Bytes blocked;
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

Bytes make_ass_video() {
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
  assert(avcodec_open2(encoder, codec, nullptr) == 0);
  AVStream *video = avformat_new_stream(format, nullptr);
  assert(video);
  video->time_base = encoder->time_base;
  assert(avcodec_parameters_from_context(video->codecpar, encoder) == 0);

  AVStream *subtitle = avformat_new_stream(format, nullptr);
  assert(subtitle);
  subtitle->time_base = AVRational{1, 1000};
  subtitle->codecpar->codec_type = AVMEDIA_TYPE_SUBTITLE;
  subtitle->codecpar->codec_id = AV_CODEC_ID_ASS;
  const size_t header_size = std::strlen(kAssHeader);
  subtitle->codecpar->extradata = static_cast<uint8_t *>(
      av_mallocz(header_size + AV_INPUT_BUFFER_PADDING_SIZE));
  assert(subtitle->codecpar->extradata);
  std::memcpy(subtitle->codecpar->extradata, kAssHeader, header_size);
  subtitle->codecpar->extradata_size = static_cast<int>(header_size);
  assert(avformat_write_header(format, nullptr) == 0);

  const char *event = "0,0,Default,,0,0,0,,VISIBLE SUBTITLE";
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
  if (std::strcmp(url, "external.ass") == 0)
    return new Bytes(media->external);
  if (std::strcmp(url, "invalid.ass") == 0)
    return new Bytes(media->invalid);
  if (std::strcmp(url, "read-failure.ass") == 0)
    return new Bytes(media->read_failure);
  if (std::strcmp(url, "blocked.ass") == 0)
    return new Bytes(media->blocked);
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
  const size_t count = std::min(static_cast<size_t>(size),
                                bytes->data.size() - bytes->offset);
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

RillightCoreSnapshot snapshot(RillightCore *core) {
  RillightCoreSnapshot state{};
  state.struct_size = sizeof(state);
  assert(rillight_core_snapshot(core, &state) == 0);
  return state;
}

template <typename Predicate>
bool wait_for(RillightCore *core, Predicate predicate,
              bool drain_video = false) {
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(5);
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
  Media media{make_ass_video(), make_external_ass(), {}, {}, {}, {}};
  media.invalid.data = {'n', 'o', 't', ' ', 'A', 'S', 'S'};
  media.read_failure.fail_read = true;
  media.blocked.block = &media.blocking;
  RillightCoreIo io{&media, open, read, seek, close, cancel};
  RillightCore *core = rillight_core_create(&io);
  assert(core && rillight_core_open(core, "synthetic.mkv", 1) == 0);
  assert(wait_for(core, [](const auto &state) {
    return state.first_video_frame_ready && state.subtitle_stream_index >= 0;
  }));
  assert(rillight_core_track_count(core) == 2);
  const auto initial = snapshot(core);
  bool embedded_rendered = false;
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
  std::printf("Embedded and external ASS subtitle composition verified (%d "
              "external frames)\n", frames);
  return 0;
}
