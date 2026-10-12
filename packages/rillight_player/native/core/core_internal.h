#pragma once

#include "core_state.h"
#include "core_video.h"
#include "core_audio.h"
#include "core_tracks.h"

namespace rillight::core {
// core_decode.cpp
int decode_tunnel_packet(RillightCoreImpl* core, Decoder& decoder,
                         const AVPacket* packet, uint64_t timeline);
int decode_packet(RillightCoreImpl *core, AVFormatContext *format,
                  Decoder &decoder, const AVPacket *packet, int video_index,
                  VideoScale *scale, AudioFilter *audio_filter,
                  std::vector<SubtitleCue> *cues, AssRenderer *ass,
                  double speed,
                  uint64_t session, uint64_t timeline, std::mutex *subtitle_mutex = nullptr,
                  const VideoSink *video_sink = nullptr);
// core_session.cpp
bool complete_mp4_header(AVFormatContext* format);
Decoder open_video_decoder(RillightCoreImpl *core, AVFormatContext *format,
                           int index, int64_t discard_before_us = -1);
void run(RillightCoreImpl *core, uint64_t session);
void stop_worker(RillightCoreImpl *core);
}  // namespace rillight::core
