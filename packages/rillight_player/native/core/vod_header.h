#pragma once

#include <algorithm>
#include <string_view>
extern "C" {
#include <libavformat/avformat.h>
#include <libavutil/mathematics.h>
}

namespace rillight::core {
// Complete VOD headers already describe supported decoders. Retain full
// probing for live/fragmented files and missing codec or timing parameters.
inline bool complete_vod_header(AVFormatContext* format) {
  if (!format || !format->iformat || !format->iformat->name ||
      (format->ctx_flags & AVFMTCTX_NOHEADER)) return false;
  const std::string_view name(format->iformat->name);
  const bool mp4 = name.find("mov,mp4") == 0;
  const bool matroska = name == "matroska,webm";
  if (!mp4 && !matroska) return false;
  if (matroska && format->duration <= 0) return false;
  bool video = false;
  int64_t duration = 0;
  for (unsigned int i = 0; i < format->nb_streams; ++i) {
    const auto* stream = format->streams[i];
    const auto* parameters = stream->codecpar;
    if (parameters->codec_type == AVMEDIA_TYPE_VIDEO &&
        !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
      if (parameters->codec_id != AV_CODEC_ID_H264 &&
          parameters->codec_id != AV_CODEC_ID_HEVC &&
          parameters->codec_id != AV_CODEC_ID_AV1 &&
          parameters->codec_id != AV_CODEC_ID_MPEG4) return false;
      if (parameters->width <= 0 || parameters->height <= 0 ||
          parameters->extradata_size <= 0 ||
          (mp4 && (stream->nb_frames <= 0 || stream->duration <= 0)) ||
          stream->time_base.num <= 0 || stream->time_base.den <= 0 ||
          (stream->avg_frame_rate.num <= 0 && stream->r_frame_rate.num <= 0))
        return false;
      video = true;
    } else if (parameters->codec_type == AVMEDIA_TYPE_AUDIO) {
      // Unknown MP4 sample entries cannot become playable by probing their
      // payload. They must not block fully described supported tracks.
      if (parameters->codec_id != AV_CODEC_ID_NONE &&
          (parameters->sample_rate <= 0 || parameters->ch_layout.nb_channels <= 0))
        return false;
    }
    if (stream->duration > 0 && stream->time_base.num > 0 && stream->time_base.den > 0)
      duration = std::max(duration, av_rescale_q(stream->duration,
                           stream->time_base, AVRational{1, AV_TIME_BASE}));
  }
  if (!video || (mp4 && duration <= 0)) return false;
  if (format->duration == AV_NOPTS_VALUE) format->duration = duration;
  return true;
}

}  // namespace rillight::core
