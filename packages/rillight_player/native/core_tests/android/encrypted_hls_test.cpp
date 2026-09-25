#include "rillight_core.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/aes.h>
#include <libavutil/error.h>
#include <libavutil/log.h>
}

namespace {
constexpr char kHttpOrigin[] = "http://127.0.0.1:18765/";
constexpr char kPrivateFileOrigin[] =
    "file:///data/user/0/com.rillight/files/hls-test/";

struct Fixture;

struct Source {
  std::vector<uint8_t> bytes;
  size_t offset = 0;
  Fixture *fixture = nullptr;
  std::string url;
};

struct Fixture {
  std::map<std::string, std::vector<uint8_t>> files;
  std::mutex mutex;
  std::set<std::string> opened;
  std::set<std::string> denied;
  bool inject_eagain = false;
  bool eagain_fired = false;
};

int write_packets(AVCodecContext *encoder, AVFormatContext *format,
                  AVStream *stream, AVPacket *packet) {
  int result;
  while ((result = avcodec_receive_packet(encoder, packet)) >= 0) {
    av_packet_rescale_ts(packet, encoder->time_base, stream->time_base);
    packet->stream_index = stream->index;
    result = av_interleaved_write_frame(format, packet);
    av_packet_unref(packet);
    if (result < 0) return result;
  }
  return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}

std::vector<uint8_t> make_mpegts(int64_t first_sample) {
  AVFormatContext *format = nullptr;
  assert(avformat_alloc_output_context2(&format, nullptr, "mpegts", nullptr) == 0);
  assert(avio_open_dyn_buf(&format->pb) >= 0);
  const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_MP2);
  assert(codec);
  AVCodecContext *encoder = avcodec_alloc_context3(codec);
  assert(encoder);
  encoder->sample_fmt = AV_SAMPLE_FMT_S16;
  encoder->sample_rate = 48000;
  encoder->bit_rate = 128000;
  encoder->time_base = AVRational{1, 48000};
  av_channel_layout_default(&encoder->ch_layout, 2);
  assert(avcodec_open2(encoder, codec, nullptr) == 0);
  assert(encoder->frame_size > 0);
  AVStream *stream = avformat_new_stream(format, nullptr);
  assert(stream);
  stream->time_base = encoder->time_base;
  assert(avcodec_parameters_from_context(stream->codecpar, encoder) == 0);
  assert(avformat_write_header(format, nullptr) == 0);

  AVFrame *frame = av_frame_alloc();
  AVPacket *packet = av_packet_alloc();
  assert(frame && packet);
  frame->format = encoder->sample_fmt;
  frame->sample_rate = encoder->sample_rate;
  frame->nb_samples = encoder->frame_size;
  assert(av_channel_layout_copy(&frame->ch_layout, &encoder->ch_layout) == 0);
  assert(av_frame_get_buffer(frame, 0) == 0);
  for (int index = 0; index < 9; ++index) {
    assert(av_frame_make_writable(frame) == 0);
    auto *samples = reinterpret_cast<int16_t *>(frame->data[0]);
    for (int sample = 0; sample < frame->nb_samples; ++sample) {
      const int16_t value = static_cast<int16_t>(
          ((first_sample + index * frame->nb_samples + sample) % 97) * 180);
      samples[2 * sample] = value;
      samples[2 * sample + 1] = -value;
    }
    frame->pts = first_sample + static_cast<int64_t>(index) * frame->nb_samples;
    assert(avcodec_send_frame(encoder, frame) == 0);
    assert(write_packets(encoder, format, stream, packet) == 0);
  }
  assert(avcodec_send_frame(encoder, nullptr) == 0);
  assert(write_packets(encoder, format, stream, packet) == 0);
  assert(av_write_trailer(format) == 0);

  uint8_t *data = nullptr;
  const int size = avio_close_dyn_buf(format->pb, &data);
  assert(size > 0 && data);
  std::vector<uint8_t> bytes(data, data + size);
  av_free(data);
  av_packet_free(&packet);
  av_frame_free(&frame);
  avcodec_free_context(&encoder);
  avformat_free_context(format);
  return bytes;
}

std::vector<uint8_t> encrypt_segment(std::vector<uint8_t> plain,
                                     const std::array<uint8_t, 16> &key,
                                     const std::array<uint8_t, 16> &iv) {
  const uint8_t padding = static_cast<uint8_t>(16 - plain.size() % 16);
  plain.insert(plain.end(), padding, padding);
  std::vector<uint8_t> encrypted(plain.size());
  AVAES *aes = av_aes_alloc();
  assert(aes && av_aes_init(aes, key.data(), 128, 0) == 0);
  auto working_iv = iv;
  av_aes_crypt(aes, encrypted.data(), plain.data(),
               static_cast<int>(plain.size() / 16), working_iv.data(), 0);
  av_free(aes);
  return encrypted;
}

void *open(void *opaque, const char *url, int) {
  auto *fixture = static_cast<Fixture *>(opaque);
  const std::string address(url ? url : "");
  std::lock_guard lock(fixture->mutex);
  const auto file = fixture->files.find(address);
  if (file == fixture->files.end()) {
    fixture->denied.insert(address);
    return nullptr;
  }
  fixture->opened.insert(address);
  return new Source{file->second, 0, fixture, address};
}

int read(void *, void *opaque, uint8_t *output, int size) {
  auto *source = static_cast<Source *>(opaque);
  if (size <= 0) return -1;
  if (source->url.find("seg1.ts") != std::string::npos) {
    std::lock_guard lock(source->fixture->mutex);
    if (source->fixture->inject_eagain && !source->fixture->eagain_fired) {
      source->fixture->eagain_fired = true;
      return AVERROR(EAGAIN);
    }
  }
  const size_t count = std::min(static_cast<size_t>(size),
                                source->bytes.size() - source->offset);
  if (count == 0) return 0;
  std::memcpy(output, source->bytes.data() + source->offset, count);
  source->offset += count;
  return static_cast<int>(count);
}

int64_t seek(void *, void *opaque, int64_t offset, int whence) {
  auto *source = static_cast<Source *>(opaque);
  if (whence & 0x10000) return static_cast<int64_t>(source->bytes.size());
  int64_t base = 0;
  switch (whence & 0xffff) {
    case 0: break;
    case 1: base = static_cast<int64_t>(source->offset); break;
    case 2: base = static_cast<int64_t>(source->bytes.size()); break;
    default: return -1;
  }
  const int64_t target = base + offset;
  if (target < 0 || target > static_cast<int64_t>(source->bytes.size()))
    return -1;
  source->offset = static_cast<size_t>(target);
  return target;
}

void close(void *, void *opaque) { delete static_cast<Source *>(opaque); }
void cancel(void *) {}

}  // namespace

int main(int argc, char **argv) {
  av_log_set_flags(AV_LOG_SKIP_REPEATED);
  bool http = false;
  bool bad_padding = false;
  bool missing_key = false;
  bool eagain = false;
  for (int index = 1; index < argc; ++index) {
    if (std::strcmp(argv[index], "--http") == 0) http = true;
    else if (std::strcmp(argv[index], "--bad-padding") == 0) bad_padding = true;
    else if (std::strcmp(argv[index], "--missing-key") == 0) missing_key = true;
    else if (std::strcmp(argv[index], "--eagain") == 0) eagain = true;
    else assert(false && "Unknown test option");
  }
  assert((bad_padding ? 1 : 0) + (missing_key ? 1 : 0) + (eagain ? 1 : 0) <= 1);
  const std::string origin = http ? kHttpOrigin : kPrivateFileOrigin;
  // FFmpeg's HLS file-protocol allow-list excludes .bin. The key bytes are
  // unchanged; .ts only lets the pinned network-disabled Linux SDK reach IO.
  const std::string key_name = http ? "key.bin" : "key.ts";
  const std::array<uint8_t, 16> key = {0x10, 0x11, 0x12, 0x13, 0x14, 0x15,
      0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f};
  const std::array<uint8_t, 16> iv0 = {0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
      0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f};
  const std::array<uint8_t, 16> iv1 = {0x0f, 0x0e, 0x0d, 0x0c, 0x0b, 0x0a,
      0x09, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00};
  const std::string playlist =
      std::string("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n") +
      "#EXT-X-MEDIA-SEQUENCE:0\n" +
      "#EXT-X-KEY:METHOD=AES-128,URI=\"" + key_name + "\","
      "IV=0x000102030405060708090a0b0c0d0e0f\n"
      "#EXTINF:0.216,\nseg0.ts\n" +
      "#EXT-X-KEY:METHOD=AES-128,URI=\"" + key_name + "\","
      "IV=0x0f0e0d0c0b0a09080706050403020100\n"
      "#EXTINF:0.216,\nseg1.ts\n#EXT-X-ENDLIST\n";
  Fixture fixture;
  fixture.inject_eagain = eagain;
  fixture.files[origin + "index.m3u8"] =
      std::vector<uint8_t>(playlist.begin(), playlist.end());
  if (!missing_key)
    fixture.files[origin + key_name] =
        std::vector<uint8_t>(key.begin(), key.end());
  fixture.files[origin + "seg0.ts"] =
      encrypt_segment(make_mpegts(0), key, iv0);
  auto second = encrypt_segment(make_mpegts(9 * 1152), key, iv1);
  if (bad_padding) {
    assert(second.size() >= 32);
    // CBC: flipping the preceding block's last byte deterministically breaks
    // the final PKCS#7 byte while preserving the earlier MPEG-TS packets.
    second[second.size() - 17] ^= 0x7f;
  }
  fixture.files[origin + "seg1.ts"] = std::move(second);
  RillightCoreIo io{};
  io.opaque = &fixture;
  io.open = open;
  io.read = read;
  io.seek = seek;
  io.close = close;
  io.cancel = cancel;
  io.cancel_media_io = cancel;
  RillightCore *core = rillight_core_create(&io);
  assert(core);
  assert(rillight_core_configure_hardware(core, RILLIGHT_CORE_HW_NONE, 1) == 0);
  assert(rillight_core_open(core, (origin + "index.m3u8").c_str(), 1) == 0);

  bool decoded = false;
  bool saw_eof = false;
  int64_t max_audio_pts = -1;
  int final_state = -1;
  int ffmpeg_error = 0;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(7);
  while (std::chrono::steady_clock::now() < deadline) {
    RillightCoreSnapshot snapshot{};
    snapshot.struct_size = sizeof(snapshot);
    assert(rillight_core_snapshot(core, &snapshot) == 0);
    final_state = snapshot.state;
    ffmpeg_error = snapshot.ffmpeg_error;
    saw_eof = snapshot.source_eof != 0;
    if (snapshot.state == RILLIGHT_CORE_FAILED) break;
    if ((bad_padding || missing_key) && saw_eof) break;
    RillightCoreFrame *frame = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16);
    if (frame) {
      assert(frame->sample_rate == 48000 && frame->channels == 2);
      max_audio_pts = std::max(max_audio_pts, frame->pts_us);
      for (int offset = 0; offset + 1 < frame->data_size; offset += 2) {
        if (frame->data[offset] != 0 || frame->data[offset + 1] != 0) {
          decoded = true;
          break;
        }
      }
      rillight_core_release_frame(frame);
    }
    if (!bad_padding && !missing_key && saw_eof && decoded &&
        max_audio_pts >= 200000) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  rillight_core_destroy(core);
  for (const auto &url : fixture.opened) std::fprintf(stderr, "opened: %s\n", url.c_str());
  for (const auto &url : fixture.denied) std::fprintf(stderr, "denied: %s\n", url.c_str());
  std::fprintf(stderr, "state=%d ffmpeg=%d eof=%d decoded=%d max_pts=%lld\n",
               final_state, ffmpeg_error, saw_eof, decoded,
               static_cast<long long>(max_audio_pts));
  const std::set<std::string> expected = {origin + "index.m3u8",
      origin + key_name, origin + "seg0.ts", origin + "seg1.ts"};
  if (missing_key) {
    assert(fixture.opened.count(origin + "index.m3u8") == 1);
    assert(fixture.denied == std::set<std::string>{origin + key_name});
  } else {
    assert(fixture.denied.empty());
    assert(fixture.opened == expected);
  }
  if (bad_padding || missing_key) {
    assert(final_state == RILLIGHT_CORE_FAILED);
    assert(ffmpeg_error < 0);
    assert(!saw_eof);
  } else {
    assert(fixture.eagain_fired == eagain);
    assert(decoded);
    assert(saw_eof);
    assert(max_audio_pts >= 200000);
  }
}
