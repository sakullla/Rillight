#ifndef RILLIGHT_VIDEO_FRAME_COST_H_
#define RILLIGHT_VIDEO_FRAME_COST_H_

extern "C" {
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
}

// Queue depth bounds opaque decoder buffers; byte budgeting applies to actual
// CPU/download planes. A MediaCodec Surface buffer has no CPU image layout.
inline int video_frame_cost(const AVFrame* frame) {
  if (!frame || frame->width <= 0 || frame->height <= 0) return -1;
  if (frame->format == AV_PIX_FMT_MEDIACODEC && frame->data[3]) return 1;
  auto format = static_cast<AVPixelFormat>(frame->format);
  if (frame->hw_frames_ctx)
    format = reinterpret_cast<AVHWFramesContext*>(frame->hw_frames_ctx->data)->sw_format;
  return av_image_get_buffer_size(format, frame->width, frame->height, 32);
}

#endif
