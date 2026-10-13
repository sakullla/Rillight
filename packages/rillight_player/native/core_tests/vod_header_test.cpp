#include "../core/vod_header.h"

#include <cassert>

int main() {
  auto* format = avformat_alloc_context();
  assert(format);
  format->iformat = av_find_input_format("matroska");
  assert(format->iformat);
  format->duration = 10000000;
  auto* video = avformat_new_stream(format, nullptr);
  auto* audio = avformat_new_stream(format, nullptr);
  assert(video && audio);
  video->codecpar->codec_type = AVMEDIA_TYPE_VIDEO;
  video->codecpar->codec_id = AV_CODEC_ID_HEVC;
  video->codecpar->width = 3840;
  video->codecpar->height = 2160;
  video->codecpar->extradata = static_cast<uint8_t*>(av_mallocz(64));
  video->codecpar->extradata_size = 64;
  video->time_base = {1, 1000};
  video->avg_frame_rate = {24000, 1001};
  audio->codecpar->codec_type = AVMEDIA_TYPE_AUDIO;
  audio->codecpar->codec_id = AV_CODEC_ID_TRUEHD;
  audio->codecpar->sample_rate = 48000;
  av_channel_layout_default(&audio->codecpar->ch_layout, 8);
  assert(rillight::core::complete_vod_header(format));
  format->duration = AV_NOPTS_VALUE;
  assert(!rillight::core::complete_vod_header(format));
  format->duration = 10000000;
  audio->codecpar->sample_rate = 0;
  assert(!rillight::core::complete_vod_header(format));
  audio->codecpar->sample_rate = 48000;
  video->codecpar->extradata_size = 0;
  assert(!rillight::core::complete_vod_header(format));
  video->codecpar->extradata_size = 64;
  video->avg_frame_rate = {0, 1};
  assert(!rillight::core::complete_vod_header(format));
  video->avg_frame_rate = {24000, 1001};
  format->ctx_flags |= AVFMTCTX_NOHEADER;
  assert(!rillight::core::complete_vod_header(format));
  format->ctx_flags = 0;
  format->iformat = av_find_input_format("mov");
  assert(!rillight::core::complete_vod_header(format));
  video->nb_frames = 240;
  video->duration = 10000;
  assert(rillight::core::complete_vod_header(format));
  avformat_free_context(format);
}
