#include "../../../linux/audio_schedule.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <thread>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
}

namespace {
struct Media {
  std::vector<uint8_t> bytes;
};
struct Handle {
  Media* media;
  int64_t offset = 0;
};

void* open_media(void* opaque, const char* url, int) {
  if (std::strcmp(url, "short-audio.mkv") != 0) return nullptr;
  return new Handle{static_cast<Media*>(opaque)};
}
int read_media(void*, void* opaque, uint8_t* data, int size) {
  auto* handle = static_cast<Handle*>(opaque);
  const auto remaining = static_cast<int64_t>(handle->media->bytes.size()) -
                         handle->offset;
  const int count = static_cast<int>(std::min<int64_t>(size, remaining));
  if (count <= 0) return 0;
  std::memcpy(data, handle->media->bytes.data() + handle->offset, count);
  handle->offset += count;
  return count;
}
int64_t seek_media(void*, void* opaque, int64_t offset, int whence) {
  auto* handle = static_cast<Handle*>(opaque);
  const int64_t size = handle->media->bytes.size();
  if (whence == AVSEEK_SIZE) return size;
  const int mode = whence & ~AVSEEK_FORCE;
  int64_t target = offset;
  if (mode == SEEK_CUR) target += handle->offset;
  else if (mode == SEEK_END) target += size;
  else if (mode != SEEK_SET) return AVERROR(EINVAL);
  if (target < 0 || target > size) return AVERROR(EINVAL);
  handle->offset = target;
  return target;
}
void close_media(void*, void* opaque) { delete static_cast<Handle*>(opaque); }
void cancel_media(void*) {}

void write_video(AVFormatContext* output, AVCodecContext* encoder,
                 AVStream* stream, AVFrame* frame) {
  assert(avcodec_send_frame(encoder, frame) == 0);
  auto* packet = av_packet_alloc();
  assert(packet);
  while (avcodec_receive_packet(encoder, packet) == 0) {
    av_packet_rescale_ts(packet, encoder->time_base, stream->time_base);
    packet->stream_index = stream->index;
    assert(av_interleaved_write_frame(output, packet) == 0);
    av_packet_unref(packet);
  }
  av_packet_free(&packet);
}

Media make_media() {
  AVFormatContext* output = nullptr;
  assert(avformat_alloc_output_context2(&output, nullptr, "matroska", nullptr) == 0);
  assert(avio_open_dyn_buf(&output->pb) >= 0);
  const auto* codec = avcodec_find_encoder(AV_CODEC_ID_MPEG4);
  assert(codec);
  auto* encoder = avcodec_alloc_context3(codec);
  assert(encoder);
  encoder->width = 32;
  encoder->height = 32;
  encoder->pix_fmt = AV_PIX_FMT_YUV420P;
  encoder->time_base = AVRational{1, 10};
  encoder->framerate = AVRational{10, 1};
  encoder->bit_rate = 100000;
  assert(avcodec_open2(encoder, codec, nullptr) == 0);
  auto* video = avformat_new_stream(output, nullptr);
  assert(video);
  video->time_base = encoder->time_base;
  assert(avcodec_parameters_from_context(video->codecpar, encoder) == 0);
  auto* audio = avformat_new_stream(output, nullptr);
  assert(audio);
  audio->time_base = AVRational{1, 48000};
  audio->codecpar->codec_type = AVMEDIA_TYPE_AUDIO;
  audio->codecpar->codec_id = AV_CODEC_ID_PCM_S16LE;
  audio->codecpar->sample_rate = 48000;
  audio->codecpar->format = AV_SAMPLE_FMT_S16;
  av_channel_layout_default(&audio->codecpar->ch_layout, 2);
  assert(avformat_write_header(output, nullptr) == 0);

  auto* frame = av_frame_alloc();
  assert(frame);
  frame->format = encoder->pix_fmt;
  frame->width = encoder->width;
  frame->height = encoder->height;
  assert(av_frame_get_buffer(frame, 32) == 0);
  for (int i = 0; i < 20; ++i) {
    assert(av_frame_make_writable(frame) == 0);
    for (int y = 0; y < frame->height; ++y)
      std::memset(frame->data[0] + y * frame->linesize[0], 30 + i * 8,
                  frame->width);
    for (int y = 0; y < frame->height / 2; ++y) {
      std::memset(frame->data[1] + y * frame->linesize[1], 128,
                  frame->width / 2);
      std::memset(frame->data[2] + y * frame->linesize[2], 128,
                  frame->width / 2);
    }
    frame->pts = i;
    write_video(output, encoder, video, frame);
    if (i >= 2) continue;
    auto* pcm = av_packet_alloc();
    assert(pcm && av_new_packet(pcm, 4800 * 4) == 0);
    std::memset(pcm->data, 0, pcm->size);
    pcm->stream_index = audio->index;
    pcm->pts = pcm->dts = i * 4800;
    pcm->duration = 4800;
    assert(av_interleaved_write_frame(output, pcm) == 0);
    av_packet_free(&pcm);
  }
  write_video(output, encoder, video, nullptr);
  assert(av_write_trailer(output) == 0);
  uint8_t* buffer = nullptr;
  const int size = avio_close_dyn_buf(output->pb, &buffer);
  assert(size > 0);
  Media media;
  media.bytes.assign(buffer, buffer + size);
  av_free(buffer);
  av_frame_free(&frame);
  avcodec_free_context(&encoder);
  avformat_free_context(output);
  return media;
}

RillightCoreSnapshot snapshot(RillightCore* core) {
  RillightCoreSnapshot value{};
  value.struct_size = sizeof(value);
  assert(rillight_core_snapshot(core, &value) == 0);
  return value;
}
}  // namespace

int main() {
  assert(rillight_core_abi_version() == RILLIGHT_CORE_ABI_VERSION);
  Media media = make_media();
  RillightCoreIo io{&media, open_media, read_media, seek_media, close_media,
                    nullptr, cancel_media};
  auto* core = rillight_core_create(&io);
  assert(core && rillight_core_open(core, "short-audio.mkv", 1) == 0);
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(8);
  rillight_linux::AudioHandoffPolicy policy;
  int64_t last_audio_end = -1;
  int64_t last_video_pts = -1;
  bool handed_off = false;
  bool output_drained = false;
  while (std::chrono::steady_clock::now() < deadline) {
    auto state = snapshot(core);
    assert(state.state != RILLIGHT_CORE_FAILED);
    if (state.state == RILLIGHT_CORE_ENDED) break;
    if (auto* frame = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16)) {
      if (frame->pts_us >= 0) {
        last_audio_end = frame->pts_us +
            frame->sample_count * 1000000LL / frame->sample_rate;
        assert(rillight_core_report_audio_played(core, frame->session_id,
                    frame->timeline_version, last_audio_end, 0) == 0);
      }
      rillight_core_release_frame(frame);
    }
    state = snapshot(core);
    if (policy.ShouldHandoff(state, false, 0, last_audio_end >= 0 &&
            !handed_off, std::chrono::steady_clock::now())) {
      assert(rillight_core_report_audio_unavailable(core, state.session_id,
                                                  state.timeline_version) == 0);
      handed_off = true;
    }
    if (auto* frame = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA)) {
      last_video_pts = std::max(last_video_pts, frame->pts_us);
      rillight_core_release_frame(frame);
    }
    state = snapshot(core);
    if (state.source_eof && state.queued_video_frames == 0 &&
        state.queued_audio_frames == 0 && !output_drained) {
      assert(rillight_core_report_output_drained(core, state.session_id,
                                                state.timeline_version) == 0);
      output_drained = true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  assert(handed_off);
  assert(last_audio_end > 0 && last_audio_end < 500000);
  assert(last_video_pts > 1500000);
  assert(output_drained);
  assert(snapshot(core).state == RILLIGHT_CORE_ENDED);
  rillight_core_destroy(core);
  return 0;
}
