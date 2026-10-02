#include "../core/rillight_core.h"

#include <algorithm>
#include <cassert>
#include <cerrno>
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
  bool eof_error = false;
  Blocking *block = nullptr;
  int slow_progress_reads = 0;
  bool eagain_after_progress = false;
  size_t stall_at_offset = 0;
};

struct Media {
  Bytes video;
  Bytes hdr_video;
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

Bytes make_ass_video(AVCodecID subtitle_codec = AV_CODEC_ID_ASS, bool hdr = false,
                     int width = 320, int height = 180,
                     const char *override_text = nullptr) {
  AVFormatContext *format = nullptr;
  const bool mov_text = subtitle_codec == AV_CODEC_ID_MOV_TEXT;
  assert(avformat_alloc_output_context2(&format, nullptr,
                                        mov_text ? "mp4" : "matroska", nullptr) == 0);
  assert(avio_open_dyn_buf(&format->pb) >= 0);
  const AVCodec *codec = avcodec_find_encoder(hdr ? AV_CODEC_ID_FFV1 : AV_CODEC_ID_MPEG4);
  assert(codec);
  AVCodecContext *encoder = avcodec_alloc_context3(codec);
  assert(encoder);
  encoder->width = width;
  encoder->height = height;
  encoder->pix_fmt = hdr ? AV_PIX_FMT_YUV420P10LE : AV_PIX_FMT_YUV420P;
  encoder->time_base = AVRational{1, 10};
  encoder->framerate = AVRational{10, 1};
  encoder->bit_rate = 300000;
  encoder->sample_aspect_ratio = AVRational{2, 1};
  encoder->color_range = AVCOL_RANGE_MPEG;
  encoder->colorspace = hdr ? AVCOL_SPC_BT2020_NCL : AVCOL_SPC_BT709;
  encoder->color_primaries = hdr ? AVCOL_PRI_BT2020 : AVCOL_PRI_BT709;
  encoder->color_trc = hdr ? AVCOL_TRC_SMPTE2084 : AVCOL_TRC_BT709;
  if (mov_text) encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
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
  if (mov_text) {
    const auto* text_codec = avcodec_find_encoder(AV_CODEC_ID_MOV_TEXT);
    assert(text_codec);
    auto* text_encoder = avcodec_alloc_context3(text_codec);
    text_encoder->width = 320;
    text_encoder->height = 180;
    text_encoder->time_base = subtitle->time_base;
    const size_t header_size = std::strlen(kAssHeader);
    text_encoder->subtitle_header = static_cast<uint8_t*>(
        av_mallocz(header_size + AV_INPUT_BUFFER_PADDING_SIZE));
    std::memcpy(text_encoder->subtitle_header, kAssHeader, header_size);
    text_encoder->subtitle_header_size = static_cast<int>(header_size);
    assert(avcodec_open2(text_encoder, text_codec, nullptr) == 0);
    assert(avcodec_parameters_from_context(subtitle->codecpar, text_encoder) == 0);
    avcodec_free_context(&text_encoder);
  }
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
  if (override_text) event = override_text;
  AVPacket *subtitle_packet = av_packet_alloc();
  assert(subtitle_packet);
  const int text_size = static_cast<int>(std::strlen(event));
  assert(av_new_packet(subtitle_packet, text_size + (mov_text ? 2 : 0)) == 0);
  if (mov_text) {
    subtitle_packet->data[0] = static_cast<uint8_t>(text_size >> 8);
    subtitle_packet->data[1] = static_cast<uint8_t>(text_size);
  }
  std::memcpy(subtitle_packet->data + (mov_text ? 2 : 0), event, text_size);
  subtitle_packet->stream_index = subtitle->index;
  subtitle_packet->pts = 0;
  subtitle_packet->dts = 0;
  subtitle_packet->duration = av_rescale_q(4000, {1, 1000}, subtitle->time_base);
  assert(av_interleaved_write_frame(format, subtitle_packet) == 0);
  av_packet_free(&subtitle_packet);

  AVFrame *frame = av_frame_alloc();
  assert(frame);
  frame->format = encoder->pix_fmt;
  frame->width = encoder->width;
  frame->height = encoder->height;
  assert(av_frame_get_buffer(frame, 32) == 0);
  for (int index = 0; index < (width > 320 ? 3 : 30); ++index) {
    assert(av_frame_make_writable(frame) == 0);
    if (hdr) {
      for (int plane = 0; plane < 3; ++plane)
        for (int row = 0; row < (plane == 0 ? frame->height : frame->height / 2); ++row)
          std::fill_n(reinterpret_cast<uint16_t*>(frame->data[plane] + row * frame->linesize[plane]),
                      plane == 0 ? frame->width : frame->width / 2, static_cast<uint16_t>(plane == 0 ? 64 : 512));
    } else {
    for (int row = 0; row < frame->height; ++row)
      std::memset(frame->data[0] + row * frame->linesize[0], 16, frame->width);
    for (int row = 0; row < frame->height / 2; ++row) {
      std::memset(frame->data[1] + row * frame->linesize[1], 128,
                  frame->width / 2);
      std::memset(frame->data[2] + row * frame->linesize[2], 128,
                  frame->width / 2);
    }
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
  if (std::strcmp(url, "synthetic.mkv") == 0 ||
      std::strcmp(url, "synthetic.mp4") == 0) return new Bytes(media->video);
  if (std::strcmp(url, "synthetic-hdr.mkv") == 0) return new Bytes(media->hdr_video);
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
      bytes->offset >= bytes->stall_at_offset) return AVERROR(EAGAIN);
  if (bytes->slow_progress_reads > 0) {
    std::this_thread::sleep_for(std::chrono::milliseconds(550));
    --bytes->slow_progress_reads;
    size = std::min(size, 32);
  } else if (bytes->eagain_after_progress) {
    bytes->eagain_after_progress = false;
    return AVERROR(EAGAIN);
  }
  if (bytes->stall_at_offset)
    size = std::min(size, 1024);
  size_t count = std::min(static_cast<size_t>(size),
                          bytes->data.size() - bytes->offset);
  if (bytes->stall_at_offset)
    count = std::min(count, bytes->stall_at_offset - bytes->offset);
  if (!count) return bytes->eof_error ? AVERROR_EOF : 0;
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
void cancel_media_io(void *) {}

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
struct InkBounds {
  int left = 100000, top = 100000, right = -1, bottom = -1;
  int height() const { return bottom - top + 1; }
  int width() const { return right - left + 1; }
};
InkBounds ink_bounds(const RillightCoreFrame *frame) {
  InkBounds bounds;
  RillightCoreSubtitleOverlay overlay{};
  overlay.struct_size = sizeof(overlay);
  const bool plane = frame->type != RILLIGHT_CORE_VIDEO_RGBA;
  if (plane) assert(rillight_core_frame_subtitle_overlay(frame, &overlay) == 0);
  const auto *data = plane ? overlay.data : frame->data;
  const int width = plane ? overlay.width : frame->width;
  const int height = plane ? overlay.height : frame->height;
  const int stride = plane ? overlay.stride : frame->stride;
  assert(data);
  for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
    const auto *pixel = data + y * stride + x * 4;
    if (pixel[0] > 100 || pixel[1] > 100 || pixel[2] > 100) {
      bounds.left = std::min(bounds.left, x + (plane ? overlay.x : 0));
      bounds.right = std::max(bounds.right, x + (plane ? overlay.x : 0));
      bounds.top = std::min(bounds.top, y + (plane ? overlay.y : 0));
      bounds.bottom = std::max(bounds.bottom, y + (plane ? overlay.y : 0));
    }
  }
  return bounds;
}

InkBounds render_fixture(const char *text, AVCodecID codec, bool plane,
                         bool original = false, double scale = 1) {
  Media media{};
  media.video = make_ass_video(codec, plane, 320, 180, text);
  RillightCoreIo io{&media, open, read, seek, close, cancel, cancel_media_io};
  auto *core = rillight_core_create(&io);
#if defined(__APPLE__)
  if (plane) assert(rillight_core_configure_macos_edr(core, 1) == 0);
#else
  assert(!plane);
#endif
  assert(rillight_core_open(core, "synthetic.mkv", 1) == 0);
  assert(rillight_core_set_playing(core, 0, 2) == 0);
  assert(wait_for(core, [](auto state) { return state.first_video_frame_ready; }));
  const auto state = snapshot(core);
  RillightCoreSubtitlePresentation p{sizeof(p), 1, 1, original ? 1 : 0,
      360, 202.5, 20, scale, 12, 8};
  assert(rillight_core_set_subtitle_presentation(core, &p, state.session_id) == 0);
  auto *frame = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
  assert(frame && (plane ? frame->type == RILLIGHT_CORE_VIDEO_RGBA16F :
                          frame->type == RILLIGHT_CORE_VIDEO_RGBA));
  auto bounds = ink_bounds(frame);
  assert(bounds.left >= 0 && bounds.right < frame->width);
  assert(bounds.top >= 0 && bounds.bottom < frame->height);
  rillight_core_release_frame(frame);
  rillight_core_destroy(core);
  return bounds;
}

void layout_presentation_test() {
  const char *chinese = "这是一段较长的中文字幕，用来确认字号增大后自动换行而不会超出视频区域";
  const auto line = render_fixture("字幕测试", AV_CODEC_ID_SUBRIP, false);
  const auto wrapped = render_fixture(chinese, AV_CODEC_ID_SUBRIP, false);
  assert(wrapped.height() > line.height() * 2);
  const auto bilingual = render_fixture("中文字幕\nEnglish subtitle", AV_CODEC_ID_WEBVTT, false);
  assert(bilingual.height() > line.height());
  const char *positioned = "0,0,Default,,0,0,0,,{\\pos(160,90)\\c&H0000FF&}POSITION";
  const auto authored = render_fixture(positioned, AV_CODEC_ID_ASS, false, true);
  const auto adjusted = render_fixture(positioned, AV_CODEC_ID_ASS, false, false, 1.5);
  assert(authored.left == adjusted.left && authored.top == adjusted.top &&
         authored.width() == adjusted.width() && authored.height() == adjusted.height());
#if defined(__APPLE__)
  const auto cpu = render_fixture("Same raster policy", AV_CODEC_ID_SUBRIP, false);
  const auto gpu = render_fixture("Same raster policy", AV_CODEC_ID_SUBRIP, true);
  assert(cpu.left == gpu.left && cpu.top == gpu.top &&
         cpu.width() == gpu.width() && cpu.height() == gpu.height());
#endif
  std::puts("Chinese wrapping, bilingual text, authored ASS position/color and CPU/HDR plane policy passed");
}

void presentation_test() {
  for (const auto codec : {AV_CODEC_ID_SUBRIP, AV_CODEC_ID_WEBVTT, AV_CODEC_ID_ASS}) {
    double previous_resolution = 0;
    for (const int height : {1080, 2160}) {
      Media media{};
      media.video = make_ass_video(codec, false, height * 16 / 9, height);
      RillightCoreIo io{&media, open, read, seek, close, cancel, cancel_media_io};
      auto *core = rillight_core_create(&io);
      assert(rillight_core_open(core, "synthetic.mkv", 1) == 0);
      assert(rillight_core_set_playing(core, 0, 2) == 0);
      assert(wait_for(core, [](auto s) { return s.first_video_frame_ready; }));
      auto *frame = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
      assert(frame);
      const auto original = ink_bounds(frame);
      const int64_t pts = frame->pts_us;
      rillight_core_release_frame(frame);
      const auto before = snapshot(core);
      RillightCoreSubtitlePresentation p{sizeof(p), 1, 1, 0,
          360, 202.5, 20, 0.85, 12, 8};
      int previous_height = 0;
      for (double scale : {0.85, 1.0, 1.25, 1.5}) {
        p.user_scale = scale;
        assert(rillight_core_set_subtitle_presentation(core, &p, before.session_id) == 0);
        frame = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
        assert(frame && frame->pts_us == pts);
        const auto bounds = ink_bounds(frame);
        assert(bounds.height() > previous_height);
        assert(bounds.left >= 0 && bounds.right < frame->width);
        previous_height = bounds.height();
        if (scale == 1.0) {
          const double displayed = bounds.height() * 202.5 / frame->height;
          if (previous_resolution) assert(std::abs(displayed - previous_resolution) < 0.6);
          previous_resolution = displayed;
        }
        rillight_core_release_frame(frame);
        const auto after = snapshot(core);
        assert(after.position_us == before.position_us);
        assert(after.timeline_version == before.timeline_version && after.state == RILLIGHT_CORE_PAUSED);
      }
      p.font_size = NAN;
      assert(rillight_core_set_subtitle_presentation(core, &p, before.session_id) != 0);
      p.font_size = 20;
      assert(rillight_core_set_subtitle_presentation(core, &p, before.session_id + 1) != 0);
      p.enabled = 0;
      assert(rillight_core_set_subtitle_presentation(core, &p, before.session_id) == 0);
      frame = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
      assert(frame);
      const auto restored = ink_bounds(frame);
      assert(restored.width() == original.width() && restored.height() == original.height());
      rillight_core_release_frame(frame);
      if (codec == AV_CODEC_ID_ASS) {
        p.enabled = p.original_ass = 1;
        assert(rillight_core_set_subtitle_presentation(core, &p, before.session_id) == 0);
        frame = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
        const auto authored = ink_bounds(frame);
        assert(authored.width() == original.width() && authored.height() == original.height());
        rillight_core_release_frame(frame);
      }
      rillight_core_destroy(core);
    }
  }
  std::puts("Real text pixels: monotonic sizing, 1080p/4K equivalence, paused redraw, original ASS and invalid/stale rejection passed");
}
}  // namespace

int main(int argc, char** argv) {
  assert(rillight_core_abi_version() == RILLIGHT_CORE_ABI_VERSION);
  if (argc > 1 && std::strcmp(argv[1], "--presentation") == 0) {
    presentation_test(); layout_presentation_test(); return 0;
  }
  if (argc > 1 && std::strcmp(argv[1], "--mov-text-only") == 0) {
    Media media{};
    media.video = make_ass_video(AV_CODEC_ID_MOV_TEXT);
    RillightCoreIo io{&media, open, read, seek, close, cancel, cancel_media_io};
    auto* core = rillight_core_create(&io);
    assert(core && rillight_core_open(core, "synthetic.mp4", 1) == 0);
    assert(wait_for(core, [](const auto& state) {
      return state.first_video_frame_ready && state.subtitle_stream_index >= 0;
    }));
    bool visible = false;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (!visible && std::chrono::steady_clock::now() < deadline) {
      if (auto* frame = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA)) {
        int white = 0;
        for (int i = 0; i + 3 < frame->data_size; i += 4)
          if (frame->data[i] > 180 && frame->data[i + 1] > 180 &&
              frame->data[i + 2] > 180) ++white;
        visible = white > 20;
        rillight_core_release_frame(frame);
      }
      if (!visible) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    assert(visible);
    const auto selected = snapshot(core).subtitle_stream_index;
    assert(rillight_core_select_subtitle(core, -1, 2) == 0);
    assert(wait_for(core, [](const auto& state) {
      return state.subtitle_stream_index == -1 && state.first_video_frame_ready;
    }));
    assert(rillight_core_select_subtitle(core, selected, 3) == 0);
    assert(wait_for(core, [selected](const auto& state) {
      return state.subtitle_stream_index == selected && state.first_video_frame_ready;
    }));
    rillight_core_destroy(core);
    std::puts("MOV_TEXT MP4 subtitle pixels and off/on selection passed");
    return 0;
  }
  Media media{};
  media.video = make_ass_video();
#if defined(_WIN32)
  media.hdr_video = make_ass_video(AV_CODEC_ID_ASS, true);
#endif
  media.srt_video = make_ass_video(AV_CODEC_ID_SUBRIP);
  media.vtt_video = make_ass_video(AV_CODEC_ID_WEBVTT);
  media.srt_video.stall_at_offset = media.srt_video.data.size() - 1;
  media.vtt_video.stall_at_offset = media.vtt_video.data.size() - 1;
  media.external = make_external_ass();
  media.external_srt = text_bytes(
      "1\n00:00:01,000 --> 00:00:02,000\nEXTERNAL SRT\n\n");
  media.external_srt.eof_error = true;
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
                    cancel_media_io};
  RillightCore *core = rillight_core_create(&io);
#if defined(_WIN32)
  assert(core && rillight_core_configure_gpu_video(core, 1) == 0);
  assert(rillight_core_configure_hdr_video(core, 1) == 0);
  assert(rillight_core_open(core, "synthetic-hdr.mkv", 1) == 0);
  bool hdr_subtitles = false;
  RillightCoreFrame* retained = nullptr;
  std::vector<uint8_t> retained_overlay;
  const auto hdr_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
  while (std::chrono::steady_clock::now() < hdr_deadline && !hdr_subtitles) {
    auto* picture = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_D3D11);
    if (!picture) { std::this_thread::sleep_for(std::chrono::milliseconds(5)); continue; }
    assert(picture->type == RILLIGHT_CORE_VIDEO_D3D11 && picture->data == nullptr);
    RillightCoreSubtitleOverlay overlay{}; overlay.struct_size = sizeof(overlay);
    assert(rillight_core_frame_subtitle_overlay(picture, &overlay) == 0);
    if (overlay.data && overlay.width > 0 && overlay.height > 0) {
      assert(overlay.x >= 0 && overlay.y >= 0 && overlay.x + overlay.width <= picture->width);
      assert(overlay.y + overlay.height <= picture->height && overlay.height < picture->height);
      bool ink = false;
      for (int y = 0; y < overlay.height; ++y)
        for (int x = 0; x < overlay.width; ++x) {
          const auto* pixel = overlay.data + static_cast<size_t>(y) * overlay.stride + x * 4;
          ink |= pixel[3] > 0 && pixel[0] > 0;
          for (int c = 0; c < 3; ++c) assert(pixel[c] <= pixel[3]);
        }
      assert(ink);
      if (!retained) {
        retained = picture;
        retained_overlay.assign(overlay.data, overlay.data + static_cast<size_t>(overlay.stride) * overlay.height);
        continue;
      }
      RillightCoreSubtitleOverlay held{}; held.struct_size = sizeof(held);
      assert(rillight_core_frame_subtitle_overlay(retained, &held) == 0);
      assert(std::memcmp(held.data, retained_overlay.data(), retained_overlay.size()) == 0);
      hdr_subtitles = true;
    }
    rillight_core_release_frame(picture);
  }
  assert(hdr_subtitles);
  rillight_core_release_frame(retained);
  rillight_core_destroy(core);
  core = rillight_core_create(&io);
#endif
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
            "(expected ABI=%u size=%zu SAR=2/1 rotation=-90 range=%d "
            "space=%d primaries=%d transfer=%d)\n",
            rillight_core_abi_version(), frame->struct_size,
            frame->sar_num, frame->sar_den, frame->has_display_matrix,
            rotation, frame->source_color_range, frame->source_color_space,
            frame->source_color_primaries, frame->source_color_transfer,
            RILLIGHT_CORE_ABI_VERSION, sizeof(*frame), AVCOL_RANGE_MPEG, AVCOL_SPC_BT709,
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
    assert(rillight_core_set_playing(core, 0, 7) == 0);
    const auto paused = snapshot(core);
    RillightCoreSubtitlePresentation presentation{sizeof(presentation), 1, 1, 0,
        360, 202.5, 20, 0.85, 12, 8};
    assert(rillight_core_set_subtitle_presentation(core, &presentation, paused.session_id) == 0);
    auto *small = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
    assert(small);
    const auto small_ink = ink_bounds(small);
    const auto subtitle_pts = small->pts_us;
    rillight_core_release_frame(small);
    presentation.user_scale = 1.5;
    assert(rillight_core_set_subtitle_presentation(core, &presentation, paused.session_id) == 0);
    auto *large = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
    assert(large && large->pts_us == subtitle_pts);
    assert(ink_bounds(large).height() > small_ink.height());
    assert(snapshot(core).position_us == paused.position_us);
    rillight_core_release_frame(large);
    rillight_core_destroy(core);
  }
  // Exercise both success and rejected parse cleanup repeatedly in one
  // session; leak instrumentation can run this same executable under ASan.
  core = rillight_core_create(&io);
  assert(core && rillight_core_open(core, "synthetic.mkv", 1) == 0);
  assert(wait_for(core, [](const auto &state) {
    return state.first_video_frame_ready && state.state != RILLIGHT_CORE_FAILED;
  }));
  const auto repeated_before = snapshot(core);
  uint64_t operation = 2;
  for (int iteration = 0; iteration < 8; ++iteration) {
    assert(rillight_core_add_external_subtitle(core, "invalid.srt",
                                              operation++) == 0);
    assert(wait_for(core, [](const auto &state) {
      return !state.external_subtitle_pending && state.ffmpeg_error < 0;
    }));
    assert(rillight_core_track_count(core) == 2 + iteration);
    const char *url = iteration % 2 ? "external.vtt" : "external.srt";
    assert(rillight_core_add_external_subtitle(core, url,
                                              operation++) == 0);
    assert(wait_for(core, [](const auto &state) {
      return !state.external_subtitle_pending && state.ffmpeg_error == 0;
    }));
    assert(rillight_core_track_count(core) == 3 + iteration);
    assert(snapshot(core).subtitle_stream_index ==
               repeated_before.subtitle_stream_index &&
           snapshot(core).timeline_version == repeated_before.timeline_version);
  }
  rillight_core_destroy(core);
  std::printf("Embedded and external ASS subtitle composition verified (%d "
              "external frames)\n", frames);
  return 0;
}
