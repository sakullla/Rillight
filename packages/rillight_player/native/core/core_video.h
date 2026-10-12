#pragma once

#include "core_frames.h"

namespace rillight::core {
struct RillightCoreImpl;
struct AssRenderer;

// core_video.cpp
int64_t frame_time(const AVFrame *frame, const AVStream *stream);
int64_t media_pts_us(const RillightCoreImpl *core, int64_t pts_us);
int64_t container_origin_us(const AVFormatContext *format);
void rebase_absolute_program_pts(RillightCoreImpl *core,
                                 RillightCoreFrame *frame);
RillightCoreFrame *convert_video(const AVFrame *frame, int64_t pts,
                                 uint64_t session, uint64_t timeline,
                                 const AVStream *stream,
                                 VideoScale *scale, int output_width,
                                 int output_height, bool gpu_video = false,
                                 bool hdr_video = false,
                                 bool macos_edr = false,
                                 const AVFrame *enhancement = nullptr,
                                 int *convert_error = nullptr,
                                 bool linear_cpu = false);
int convert_video_frame(RillightCoreImpl *core, AVFormatContext *format,
                        AVFrame *decoded, int stream_index, uint32_t hardware,
                        VideoScale *scale, std::vector<SubtitleCue> *cues,
                        AssRenderer *ass, uint64_t session, uint64_t timeline,
                        std::mutex *subtitle_mutex);
}  // namespace rillight::core
