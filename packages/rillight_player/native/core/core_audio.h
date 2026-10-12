#pragma once

#include "core_frames.h"

namespace rillight::core {
struct RillightCoreImpl;

// core_audio.cpp
void close_audio_filter(AudioFilter *filter);
int prepare_audio_filter(AudioFilter *filter, const AVFrame *frame,
                         double speed, int64_t media_pts,
                         const RillightAudioContract &contract,
                         uint64_t sink_generation);
RillightCoreFrame *convert_audio(const AVFrame *frame, AudioFilter *filter,
                                 uint64_t session, uint64_t timeline);
int drain_audio_filter(RillightCoreImpl *core, AudioFilter *filter,
                       int video_index, uint64_t session, uint64_t timeline);
AudioSinkView audio_sink_view(RillightCoreImpl *core);
int packet_passthrough_kind(const AVCodecParameters *parameters,
                            const AVPacket *packet, uint32_t accept,
                            double speed);
RillightCoreFrame *passthrough_frame(const AVPacket *packet,
                                     const AVStream *stream, int kind,
                                     const AudioSinkView &view,
                                     uint64_t session, uint64_t timeline);
}  // namespace rillight::core
