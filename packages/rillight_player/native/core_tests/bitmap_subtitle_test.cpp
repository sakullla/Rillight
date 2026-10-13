#include "../core/bitmap_subtitle.h"
#include "../core/core_subtitles.h"
#include "../core/bitmap_subtitle_color.h"

#include <cassert>
#include <climits>

using namespace rillight::core;

static void segment(std::vector<uint8_t>& bytes, uint8_t kind,
                    const std::vector<uint8_t>& body) {
  bytes.push_back(kind);
  bytes.push_back(static_cast<uint8_t>(body.size() >> 8));
  bytes.push_back(static_cast<uint8_t>(body.size()));
  bytes.insert(bytes.end(), body.begin(), body.end());
}

static std::vector<uint8_t> element(uint32_t id, const std::vector<uint8_t>& body) {
  std::vector<uint8_t> bytes;
  int shift = 24;
  while (shift > 0 && !(id >> shift)) shift -= 8;
  for (; shift >= 0; shift -= 8) bytes.push_back(static_cast<uint8_t>(id >> shift));
  assert(body.size() < 16383);
  if (body.size() < 127) bytes.push_back(static_cast<uint8_t>(0x80 | body.size()));
  else {
    bytes.push_back(static_cast<uint8_t>(0x40 | (body.size() >> 8)));
    bytes.push_back(static_cast<uint8_t>(body.size()));
  }
  bytes.insert(bytes.end(), body.begin(), body.end());
  return bytes;
}

static void append(std::vector<uint8_t>& bytes, const std::vector<uint8_t>& next) {
  bytes.insert(bytes.end(), next.begin(), next.end());
}

static void read_compressed_pgs(AVPacket* packet, const std::vector<uint8_t>& expected) {
  // zlib-compressed version of the synthetic display set below. FFmpeg must
  // decompress the Matroska ContentEncoding before delivering PGS packets.
  const std::vector<uint8_t> compressed{
    0x78, 0x9c, 0x13, 0x63, 0x10, 0x66, 0x65, 0x60, 0xba, 0x20, 0xc0, 0xc0, 0xd0,
    0xc0, 0xc0, 0xc0, 0xc8, 0xc0, 0xc0, 0xc0, 0xc0, 0xf8, 0x80, 0x29, 0x42, 0x9c,
    0x81, 0x8b, 0x11, 0xcc, 0x60, 0x74, 0x60, 0xd0, 0x10, 0x61, 0xe0, 0x61, 0x60,
    0x60, 0x10, 0x68, 0x68, 0x60, 0x60, 0x7c, 0xdd, 0xd0, 0xf0, 0x5f, 0x94, 0xe1,
    0x37, 0x03, 0x03, 0xc3, 0x01, 0x06, 0x86, 0x2f, 0x20, 0x49, 0x86, 0x83, 0x0e,
    0x20, 0x5d, 0x23, 0x86, 0x6c, 0x60, 0x60, 0x00, 0x00, 0x1a, 0x98, 0x34, 0xab};
  std::vector<uint8_t> header;
  append(header, element(0x4286, {1})); append(header, element(0x42f7, {1}));
  append(header, element(0x42f2, {4})); append(header, element(0x42f3, {8}));
  append(header, element(0x4282, {'m','a','t','r','o','s','k','a'}));
  append(header, element(0x4287, {4})); append(header, element(0x4285, {2}));
  std::vector<uint8_t> track;
  append(track, element(0xd7, {1})); append(track, element(0x73c5, {1}));
  append(track, element(0x83, {17}));
  append(track, element(0x86, {'S','_','H','D','M','V','/','P','G','S'}));
  append(track, element(0x6d80, element(0x6240, element(0x5034, element(0x4254, {0})))));
  std::vector<uint8_t> block{0x81, 0, 0, 0x80};
  append(block, compressed);
  std::vector<uint8_t> cluster = element(0xe7, {3, 0xe8});
  append(cluster, element(0xa3, block));
  std::vector<uint8_t> body = element(0x1549a966, element(0x2ad7b1, {0x0f, 0x42, 0x40}));
  append(body, element(0x1654ae6b, element(0xae, track)));
  append(body, element(0x1f43b675, cluster));
  struct Input { std::vector<uint8_t> bytes; size_t offset = 0; } input{element(0x1a45dfa3, header)};
  append(input.bytes, element(0x18538067, body));
  const auto read = [](void* opaque, uint8_t* buffer, int size) {
    auto& source = *static_cast<Input*>(opaque);
    const auto count = std::min(static_cast<size_t>(size), source.bytes.size() - source.offset);
    if (!count) return AVERROR_EOF;
    std::memcpy(buffer, source.bytes.data() + source.offset, count);
    source.offset += count;
    return static_cast<int>(count);
  };
  auto* io = avio_alloc_context(static_cast<uint8_t*>(av_malloc(4096)), 4096, 0, &input, read, nullptr, nullptr);
  auto* format = avformat_alloc_context();
  assert(io && format);
  format->pb = io;
  format->flags |= AVFMT_FLAG_CUSTOM_IO;
  assert(avformat_open_input(&format, nullptr, av_find_input_format("matroska"), nullptr) == 0);
  assert(format->nb_streams == 1 && format->streams[0]->codecpar->codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE);
  assert(av_read_frame(format, packet) == 0);
  assert(packet->pts == 1000 && av_cmp_q(format->streams[0]->time_base, {1, 1000}) == 0);
  assert(packet->size == static_cast<int>(expected.size()));
  assert(std::memcmp(packet->data, expected.data(), expected.size()) == 0);
  avformat_close_input(&format);
  av_freep(&io->buffer);
  avio_context_free(&io);
}

static void decoded_pgs_pixels(bool compressed = false, int color_mode = 0) {
  Decoder decoder;
  const auto* codec = avcodec_find_decoder(AV_CODEC_ID_HDMV_PGS_SUBTITLE);
  assert(codec);
  decoder.context = avcodec_alloc_context3(codec);
  assert(decoder.context);
  const AVRational time_base{1, compressed ? 1000 : 90000};
  decoder.context->pkt_timebase = time_base;
  assert(avcodec_open2(decoder.context, codec, nullptr) == 0);
  // Real PGS composition: 1280x720 canvas, white 320x40 rectangle at 480,600.
  std::vector<uint8_t> bytes;
  segment(bytes, 0x16, {5, 0, 2, 208, 0x10, 0, 0, 0x80, 0, 0, 1,
                       0, 0, 0, 0, 1, 224, 2, 88});
  segment(bytes, 0x17, {1, 0, 1, 224, 2, 88, 1, 64, 0, 40});
  segment(bytes, 0x14, {0, 0, 0, 16, 128, 128, 0, 1, 235, 128, 128, 255});
  if (color_mode) {
    // A 149-code neutral PQ glyph, as in UHD PGS, is not SDR gray.
    segment(bytes, 0x14, {0, 1, 0, 16, 128, 128, 0, 1, 144, 128, 128, 255});
  }
  std::vector<uint8_t> object{0, 0, 0, 0xc0, 0, 0, 244, 1, 64, 0, 40};
  for (int row = 0; row < 40; ++row)
    object.insert(object.end(), {0, 0xc1, 0x40, 1, 0, 0});
  segment(bytes, 0x15, object);
  segment(bytes, 0x80, {});
  auto* packet = av_packet_alloc();
  assert(packet);
  if (compressed) read_compressed_pgs(packet, bytes);
  else {
    assert(av_new_packet(packet, static_cast<int>(bytes.size())) == 0);
    std::memcpy(packet->data, bytes.data(), bytes.size());
    packet->pts = 90000;
  }
  std::vector<SubtitleCue> cues;
  AVCodecParameters video{};
  video.color_trc = color_mode == 2 ? AVCOL_TRC_BT709 : AVCOL_TRC_SMPTE2084;
  video.color_primaries = AVCOL_PRI_BT2020;
  video.color_space = AVCOL_SPC_BT2020_NCL;
  if (color_mode == 3) video.color_trc = AVCOL_TRC_UNSPECIFIED;
  if (color_mode == 4) video.color_primaries = AVCOL_PRI_BT709;
  if (color_mode == 5) video.color_space = AVCOL_SPC_BT2020_CL;
  assert(decode_bitmap_subtitle(decoder, packet, time_base, &cues, 0, 0, 0,
                               color_mode ? &video : nullptr) == 0);
  assert(cues.size() == 1 && cues[0].bitmaps.size() == 1);
  assert(cues[0].canvas_width == 1280 && cues[0].canvas_height == 720);

  for (const int width : {1280, 640, 320}) {
    if (compressed && width != 640) continue;
    VideoOutputFrame frame{};
    frame.type = RILLIGHT_CORE_VIDEO_RGBA;
    frame.width = width;
    frame.height = width * 9 / 16;
    frame.stride = width * 4;
    frame.pts_us = 2000000;
    std::vector<uint8_t> pixels(static_cast<size_t>(frame.stride) * frame.height, 0);
    frame.data = pixels.data();
    blend_subtitles(&frame, cues);
    const int x = 480 * width / 1280, y = 600 * width / 1280;
    const size_t offset = static_cast<size_t>(y) * frame.stride + x * 4;
    // ST 2084 code 149 is 210.16 nits; the fixed SDR curve encodes it as 205.
    const int expected = color_mode == 1 ? 205 : color_mode ? 149 : 255;
    assert(std::abs(pixels[offset] - expected) <= 2 && pixels[offset + 3] == 255);
    assert(pixels[offset - 4] == 0);

    frame.type = RILLIGHT_CORE_VIDEO_ANDROID_P010;
    frame.data = nullptr;
    BitmapSubtitleOverlayCache cache;
    AssRenderer ass;
    render_gpu_subtitles(&frame, cues, &ass, &cache);
    assert(frame.subtitle_pixels);
    assert(frame.subtitle_overlay.x == x && frame.subtitle_overlay.y == y);
    assert(frame.subtitle_overlay.width == 320 * width / 1280);
    assert(frame.subtitle_overlay.height == 40 * width / 1280);
    assert((*frame.subtitle_pixels)[0] == pixels[offset] && (*frame.subtitle_pixels)[3] == 255);
    VideoOutputFrame next{};
    next.width = frame.width; next.height = frame.height; next.pts_us = frame.pts_us + 1000;
    render_gpu_subtitles(&next, cues, &ass, &cache);
    assert(next.subtitle_pixels == frame.subtitle_pixels); // Same display set reuses pixels.
    BitmapSubtitleOverlayCache secondary_cache;
    VideoOutputFrame secondary{};
    secondary.width = frame.width; secondary.height = frame.height; secondary.pts_us = frame.pts_us;
    render_gpu_subtitles(&secondary, {}, &ass, &secondary_cache, nullptr, &cues);
    assert(secondary.subtitle_overlay.x == x && secondary.subtitle_overlay.y == y);
    assert(*secondary.subtitle_pixels == *frame.subtitle_pixels);
  }
  av_packet_unref(packet);
  bytes.clear();
  segment(bytes, 0x16, {5, 0, 2, 208, 0x10, 0, 1, 0, 0, 0, 0});
  segment(bytes, 0x80, {});
  assert(av_new_packet(packet, static_cast<int>(bytes.size())) == 0);
  std::memcpy(packet->data, bytes.data(), bytes.size());
  packet->pts = av_rescale_q(270000, {1, 90000}, time_base);
  assert(decode_bitmap_subtitle(decoder, packet, time_base, &cues) == 0);
  assert(cues.size() == 1 && cues[0].end_us == 3000000);
  VideoOutputFrame cleared{};
  cleared.width = 640; cleared.height = 360; cleared.pts_us = 3000000;
  BitmapSubtitleOverlayCache cache;
  AssRenderer ass;
  render_gpu_subtitles(&cleared, cues, &ass, &cache);
  assert(!cleared.subtitle_pixels);
  av_packet_free(&packet);
  avcodec_free_context(&decoder.context);
}

static int visible(const std::vector<SubtitleCue>& cues, int64_t time) {
  int count = 0;
  for (const auto& cue : cues)
    if (cue.start_us <= time && time < cue.end_us) ++count;
  return count;
}

static void positioned_multiline_bitmap() {
  SubtitleCue cue;
  cue.start_us = 0; cue.end_us = 100; cue.identity = 1;
  cue.canvas_width = 1920; cue.canvas_height = 1080;
  // Two rows within one object and a separate vertical object. Keep the blank
  // line, relative positions and partial alpha at native and resized output.
  SubtitleBitmap lines;
  lines.x = 590; lines.y = 876; lines.width = 750; lines.height = 126;
  lines.palette = {0, 0xffd3d3d3, 0x80d3d3d3};
  lines.indices.resize(750 * 126);
  for (int y = 0; y < 126; ++y)
    for (int x = 0; x < 750; ++x)
      if (y < 50 || y >= 76) lines.indices[y * 750 + x] = x < 20 ? 2 : 1;
  SubtitleBitmap vertical;
  vertical.x = 1700; vertical.y = 148; vertical.width = 64; vertical.height = 558;
  vertical.palette = lines.palette; vertical.indices.assign(64 * 558, 1);
  cue.bitmaps = {lines, vertical};
  for (int width : {1920, 960, 640}) {
    VideoOutputFrame frame{};
    frame.type = RILLIGHT_CORE_VIDEO_RGBA;
    frame.width = width; frame.height = width * 9 / 16; frame.stride = width * 4;
    frame.pts_us = 1;
    std::vector<uint8_t> pixels(static_cast<size_t>(frame.stride) * frame.height);
    frame.data = pixels.data();
    blend_subtitles(&frame, {cue});
    const auto red = [&](int x, int y) {
      return pixels[static_cast<size_t>(y * frame.height / 1080) * frame.stride +
                    (x * width / 1920) * 4];
    };
    assert(red(800, 900) == 211 && red(800, 970) == 211);
    assert(red(800, 940) == 0 && red(1650, 200) == 0);
    assert(red(1730, 200) == 211 && red(600, 900) == 106);
    BitmapSubtitleOverlayCache cache;
    AssRenderer ass;
    render_gpu_subtitles(&frame, {cue}, &ass, &cache);
    const auto& o = frame.subtitle_overlay;
    for (int y = 0; y < o.height; ++y)
      for (int x = 0; x < o.width; ++x)
        for (int c = 0; c < 3; ++c)
          assert(o.data[y * o.stride + x * 4 + c] ==
                 pixels[static_cast<size_t>(o.y + y) * frame.stride + (o.x + x) * 4 + c]);
  }
}

int main() {
  decoded_pgs_pixels();
  decoded_pgs_pixels(true);
  decoded_pgs_pixels(false, 1);
  decoded_pgs_pixels(false, 2); // Non-PQ stays untouched.
  decoded_pgs_pixels(false, 3); // Unknown transfer is not guessed from gray.
  decoded_pgs_pixels(false, 4); // Other primaries/matrices are not inferred.
  decoded_pgs_pixels(false, 5);
  assert(pq_pgs_to_srgb(0x00123456, false) == 0x00123456);
  assert(pq_pgs_to_srgb(0x80000000, false) == 0x80000000);
  assert(pq_pgs_to_srgb(0x80ffffff, false) == 0x80ffffff);
  assert((pq_pgs_to_srgb(0x80959595, false) >> 24) == 128);
  positioned_multiline_bitmap();
  // PGS reports an open-ended display until the next display set arrives.
  std::vector<SubtitleCue> cues{{1000000, INT64_MAX, {}}};
  end_pgs_display(cues, 3000000);
  cues.push_back({3000000, INT64_MAX, {}});
  assert(visible(cues, 2000000) == 1); // Decoding ahead preserves old frames.
  assert(visible(cues, 3000000) == 1); // New text replaces rather than overlaps.

  end_pgs_display(cues, 4000000); // Empty display set: no new bitmap to append.
  assert(visible(cues, 3999999) == 1);
  assert(visible(cues, 4000000) == 0);
  assert(visible(cues, 5000000) == 0);

  cues.push_back({6000000, 6500000, {}});
  end_pgs_display(cues, 7000000);
  assert(visible(cues, 6600000) == 0); // Never extend a bounded cue.
  end_pgs_display(cues, 5000000);
  assert(visible(cues, 6200000) == 1); // Earlier events leave future cues alone.
  end_pgs_display(cues, 6000000);
  assert(visible(cues, 6000000) == 0); // Same-timestamp replacement.

  std::vector<SubtitleCue> displayed{{100, 200, {}, 1}, {200, 300, {}, 2}};
  const auto first = bitmap_subtitle_key(displayed, 100, 1920, 1080);
  assert(first == bitmap_subtitle_key(displayed, 199, 1920, 1080));
  assert(!(first == bitmap_subtitle_key(displayed, 200, 1920, 1080)));
  assert(!(first == bitmap_subtitle_key(displayed, 300, 1920, 1080)));
  assert(!(first == bitmap_subtitle_key(displayed, 100, 1280, 720)));
  // A new track or seek can reuse timestamps with different bitmap content.
  displayed[0].identity = 3;
  assert(!(first == bitmap_subtitle_key(displayed, 100, 1920, 1080)));
}
