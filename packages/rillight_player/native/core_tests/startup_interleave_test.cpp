#include "../core/rillight_core.h"

#include <algorithm>
#include <cassert>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
}

namespace {
struct Bytes {
  std::vector<uint8_t> data;
  size_t offset = 0;
};

// Valid container ordering: an audio chunk precedes the first video packet.
// Platform audio sinks do not consume PCM while the core is still OPENING.
Bytes make_media(int audio_packets = 40, int audio_start_samples = 0,
                 bool video_before_audio = false, bool regular_video = false,
                 bool resume_colors = false) {
  AVFormatContext *format = nullptr;
  assert(avformat_alloc_output_context2(&format, nullptr, "matroska", nullptr) == 0);
  format->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
  assert(avio_open_dyn_buf(&format->pb) == 0);
  const auto *codec = avcodec_find_encoder(AV_CODEC_ID_MPEG4);
  assert(codec);
  auto *encoder = avcodec_alloc_context3(codec);
  encoder->width = 64;
  encoder->height = 64;
  encoder->pix_fmt = AV_PIX_FMT_YUV420P;
  encoder->time_base = AVRational{1, 10};
  assert(avcodec_open2(encoder, codec, nullptr) == 0);
  auto *video = avformat_new_stream(format, nullptr);
  video->time_base = encoder->time_base;
  assert(avcodec_parameters_from_context(video->codecpar, encoder) == 0);
  auto *audio = avformat_new_stream(format, nullptr);
  audio->time_base = AVRational{1, 48000};
  audio->codecpar->codec_type = AVMEDIA_TYPE_AUDIO;
  audio->codecpar->codec_id = AV_CODEC_ID_PCM_S16LE;
  audio->codecpar->sample_rate = 48000;
  audio->codecpar->bits_per_coded_sample = 16;
  av_channel_layout_default(&audio->codecpar->ch_layout, 2);
  assert(avformat_write_header(format, nullptr) == 0);
  auto *packet = av_packet_alloc();
  auto *frame = av_frame_alloc();
  frame->format = encoder->pix_fmt;
  frame->width = encoder->width;
  frame->height = encoder->height;
  assert(av_frame_get_buffer(frame, 32) == 0);
  for (int plane = 0; plane < 3; ++plane)
    std::memset(frame->data[plane], plane == 0 ? 80 : 128,
                frame->linesize[plane] * (plane == 0 ? 64 : 32));
  auto write_video = [&](int pts) {
    assert(av_frame_make_writable(frame) == 0);
    if (resume_colors) {
      // A red opening card followed by green content reproduces the unwanted
      // opening-card flash when resume is implemented as open-then-seek.
      const uint8_t color[] = {
          static_cast<uint8_t>(pts < 5 ? 81 : 145),
          static_cast<uint8_t>(pts < 5 ? 90 : 54),
          static_cast<uint8_t>(pts < 5 ? 240 : 34)};
      for (int plane = 0; plane < 3; ++plane)
        std::memset(frame->data[plane], color[plane],
                    frame->linesize[plane] * (plane == 0 ? 64 : 32));
    }
    frame->pts = pts;
    assert(avcodec_send_frame(encoder, frame) == 0);
    assert(avcodec_receive_packet(encoder, packet) == 0);
    av_packet_rescale_ts(packet, encoder->time_base, video->time_base);
    packet->stream_index = video->index;
    assert(av_write_frame(format, packet) == 0);
    av_packet_unref(packet);
  };
  if (video_before_audio) write_video(0);
  for (int index = 0; index < audio_packets; ++index) {
    if (regular_video && index % 5 == 0) write_video(index / 5);
    assert(av_new_packet(packet, 960 * 4) == 0);
    std::memset(packet->data, 1, packet->size);
    packet->stream_index = audio->index;
    packet->pts = packet->dts = av_rescale_q(index * 960 + audio_start_samples,
                                           {1, 48000}, audio->time_base);
    packet->duration = av_rescale_q(960, {1, 48000}, audio->time_base);
    assert(av_write_frame(format, packet) == 0);
    av_packet_unref(packet);
  }
  if (!regular_video) write_video(video_before_audio ? 1 : 0);
  assert(av_write_trailer(format) == 0);
  av_packet_free(&packet);
  av_frame_free(&frame);
  avcodec_free_context(&encoder);
  uint8_t *data = nullptr;
  const int size = avio_close_dyn_buf(format->pb, &data);
  assert(size > 0);
  Bytes bytes{{data, data + size}};
  av_free(data);
  avformat_free_context(format);
  return bytes;
}

void *open(void *opaque, const char *, int) {
  return new Bytes(*static_cast<Bytes *>(opaque));
}
int read(void *, void *handle, uint8_t *data, int size) {
  auto *bytes = static_cast<Bytes *>(handle);
  const auto count = std::min<size_t>(size, bytes->data.size() - bytes->offset);
  std::memcpy(data, bytes->data.data() + bytes->offset, count);
  bytes->offset += count;
  return static_cast<int>(count);
}
int64_t seek(void *, void *handle, int64_t offset, int whence) {
  auto *bytes = static_cast<Bytes *>(handle);
  if (whence & AVSEEK_SIZE) return static_cast<int64_t>(bytes->data.size());
  const int64_t base = whence == SEEK_CUR ? bytes->offset :
                       whence == SEEK_END ? bytes->data.size() : 0;
  const int64_t next = base + offset;
  if (next < 0 || static_cast<uint64_t>(next) > bytes->data.size()) return -1;
  bytes->offset = next;
  return next;
}
void close(void *, void *handle) { delete static_cast<Bytes *>(handle); }
void cancel(void *) {}
}  // namespace

int main() {
  auto resume_media = make_media(120, 0, false, true, true);
  for (const int64_t start : {int64_t{0}, int64_t{700000}}) {
    RillightCoreIo io{&resume_media, open, read, seek, close, cancel, cancel};
    auto* core = rillight_core_create(&io);
    assert(core);
    assert(rillight_core_open_at(core, "resume-colors.mkv", -1, 1) != 0);
    assert(rillight_core_open_at(core, "resume-colors.mkv", start, 1) == 0);
    assert(rillight_core_set_playing(core, 0, 2) == 0);
    RillightCoreFrame* first = nullptr;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (!first && std::chrono::steady_clock::now() < deadline) {
      first = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
      if (!first) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    assert(first && first->pts_us + 5000 >= start);
    const auto* pixel = first->data + first->stride * 32 + 32 * 4;
    if (start == 0) assert(pixel[0] > 180 && pixel[1] < 80);
    else assert(pixel[1] > 180 && pixel[0] < 80);
    std::printf("atomic startup: start=%lld first_pts=%lld rgb=%d,%d,%d\n",
        static_cast<long long>(start), static_cast<long long>(first->pts_us),
        pixel[0], pixel[1], pixel[2]);
    rillight_core_release_frame(first);
    rillight_core_destroy(core);
  }
  // A blocked renderer must not starve audio. Never consume the video queue;
  // audio past its third queued picture must still decode, then close must join
  // the blocked video lane without waiting for a renderer.
  auto blocked_video = make_media(80, 0, false, true);
  {
    RillightCoreIo io{&blocked_video, open, read, seek, close, cancel, cancel};
    auto* core = rillight_core_create(&io);
    assert(core && rillight_core_open(core, "blocked-video.mkv", 1) == 0);
    int64_t last_pts = -1;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (std::chrono::steady_clock::now() < deadline && last_pts < 1000000) {
      while (auto* frame = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16)) {
        last_pts = frame->pts_us;
        rillight_core_release_frame(frame);
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    std::printf("blocked video: last audio pts=%lld\n", static_cast<long long>(last_pts));
    // Seeking while both video output and conversion are backpressured must
    // retire the old pictures and still produce a paused preview.
    assert(rillight_core_set_playing(core, 0, 2) == 0);
    assert(rillight_core_seek(core, 0, 3) == 0);
    RillightCoreSnapshot after_seek{};
    after_seek.struct_size = sizeof(after_seek);
    const auto seek_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    do {
      assert(rillight_core_snapshot(core, &after_seek) == 0);
      if (after_seek.first_video_frame_ready && after_seek.first_audio_frame_ready) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    } while (std::chrono::steady_clock::now() < seek_deadline);
    auto *preview = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
    assert(preview && preview->pts_us == 0 &&
           preview->timeline_version == after_seek.timeline_version &&
           after_seek.state == RILLIGHT_CORE_PAUSED);
    rillight_core_release_frame(preview);
    rillight_core_destroy(core);
    if (last_pts < 1000000) return 5;
  }
  // A later video packet may also follow an interleaved audio chunk. Audio
  // backpressure must not hide the next picture until its deadline has passed.
  auto interleaved = make_media(40, 0, true);
  {
    RillightCoreIo io{&interleaved, open, read, seek, close, cancel, cancel};
    auto *core = rillight_core_create(&io);
    assert(core && rillight_core_open(core, "midstream.mkv", 1) == 0);
    int video_frames = 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(400);
    while (std::chrono::steady_clock::now() < deadline && video_frames < 2) {
      if (auto *frame = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA)) {
        video_frames++;
        rillight_core_release_frame(frame);
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    std::printf("interleaved video frames=%d\n", video_frames);
    rillight_core_destroy(core);
    if (video_frames != 2) return 4;
  }
  auto negative_start = make_media(40, -960);
  {
    RillightCoreIo io{&negative_start, open, read, seek, close, cancel, cancel};
    auto *core = rillight_core_create(&io);
    assert(core && rillight_core_open(core, "negative-start.mkv", 1) == 0);
    int64_t last_audio_pts = -1;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (std::chrono::steady_clock::now() < deadline) {
      while (auto *frame = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16)) {
        last_audio_pts = frame->pts_us;
        rillight_core_release_frame(frame);
      }
      if (last_audio_pts >= 500000) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    std::printf("negative start: last audio pts=%lld\n",
                static_cast<long long>(last_audio_pts));
    rillight_core_destroy(core);
    if (last_audio_pts < 500000) return 3;
  }
  auto media = make_media();
  for (bool paused : {false, true}) {
    RillightCoreIo io{&media, open, read, seek, close, cancel, cancel};
    auto *core = rillight_core_create(&io);
    assert(core && rillight_core_open(core, "interleaved.mkv", 1) == 0);
    if (paused) assert(rillight_core_set_playing(core, 0, 2) == 0);
    RillightCoreSnapshot state{};
    state.struct_size = sizeof(state);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    do {
      assert(rillight_core_snapshot(core, &state) == 0);
      if (state.first_video_frame_ready && state.first_audio_frame_ready) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    } while (std::chrono::steady_clock::now() < deadline);
    std::printf("paused=%d state=%d firstVideo=%d audioQueue=%d\n", paused,
                state.state, state.first_video_frame_ready, state.queued_audio_frames);
    const bool ready = state.first_video_frame_ready && state.first_audio_frame_ready;
    // Preserve the leading PCM instead of dropping it to make startup appear fixed.
    auto *first_audio = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16);
    const bool audio_preserved = state.queued_audio_frames > 0 &&
        first_audio && first_audio->pts_us == 0 && first_audio->sample_count > 0;
    rillight_core_release_frame(first_audio);
    rillight_core_destroy(core);
    if (!ready || !audio_preserved) return 1;
  }
  // Oversized preroll must fail with a bounded error, never wait for a sink
  // that cannot consume until the first video packet has been reached.
  auto excessive = make_media(1400);
  RillightCoreIo io{&excessive, open, read, seek, close, cancel, cancel};
  auto *core = rillight_core_create(&io);
  assert(core && rillight_core_open(core, "excessive.mkv", 1) == 0);
  RillightCoreSnapshot state{};
  state.struct_size = sizeof(state);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  do {
    assert(rillight_core_snapshot(core, &state) == 0);
    if (state.ffmpeg_error) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  } while (std::chrono::steady_clock::now() < deadline);
  const bool bounded = state.ffmpeg_error == AVERROR(ENOBUFS) &&
      !state.first_video_frame_ready;
  rillight_core_destroy(core);
  if (!bounded) return 2;
  return 0;
}
