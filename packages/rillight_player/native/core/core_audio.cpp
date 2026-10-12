#include "core_audio.h"
#include "core_state.h"
#include "core_video.h"

namespace rillight::core {
void close_audio_filter(AudioFilter *filter) {
  avfilter_graph_free(&filter->graph);
  av_channel_layout_uninit(&filter->input_layout);
  filter->source = nullptr;
  filter->sink = nullptr;
  filter->input_rate = 0;
  filter->input_format = AV_SAMPLE_FMT_NONE;
  filter->media_anchor = AV_NOPTS_VALUE;
  filter->output_anchor = AV_NOPTS_VALUE;
  filter->next_media_pts = AV_NOPTS_VALUE;
}

int prepare_audio_filter(AudioFilter *filter, const AVFrame *frame,
                         double speed, int64_t media_pts,
                         const RillightAudioContract &contract,
                         uint64_t sink_generation) {
  if (!contract.ffmpeg_layout || contract.channels < 1) return AVERROR(EINVAL);
  if (filter->graph && filter->input_rate == frame->sample_rate &&
      filter->input_format == frame->format && filter->speed == speed &&
      filter->output_channels == contract.channels &&
      filter->output_layout == contract.layout &&
      filter->sink_generation == sink_generation &&
      av_channel_layout_compare(&filter->input_layout, &frame->ch_layout) == 0)
    return 0;
  close_audio_filter(filter);
  if (frame->sample_rate <= 0 || frame->ch_layout.nb_channels <= 0)
    return AVERROR(EINVAL);
  filter->graph = avfilter_graph_alloc();
  if (!filter->graph) return AVERROR(ENOMEM);
  char layout[128] = {};
  if (av_channel_layout_describe(&frame->ch_layout, layout,
                                 sizeof(layout)) < 0)
    return AVERROR(EINVAL);
  char args[512] = {};
  std::snprintf(args, sizeof(args),
                "time_base=1/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
                frame->sample_rate, frame->sample_rate,
                av_get_sample_fmt_name(static_cast<AVSampleFormat>(frame->format)),
                layout);
  AVFilterContext *tempo = nullptr;
  AVFilterContext *tempo_second = nullptr;
  AVFilterContext *format = nullptr;
  int result = avfilter_graph_create_filter(
      &filter->source, avfilter_get_by_name("abuffer"), "input", args,
      nullptr, filter->graph);
  if (result < 0) return result;
  if (speed != 1.0) {
    // Unity playback needs format conversion/downmix only. Running WSOLA at
    // unity adds a priming window and packet buffering to every open/seek,
    // including E-AC-3/TrueHD, without changing the requested playback speed.
    const std::string tempo_arg = std::to_string(std::min(speed, 2.0));
    result = avfilter_graph_create_filter(
        &tempo, avfilter_get_by_name("atempo"), "tempo", tempo_arg.c_str(),
        nullptr, filter->graph);
    if (result < 0) return result;
  }
  if (speed > 2.0) {
    const std::string second_arg = std::to_string(speed / 2.0);
    result = avfilter_graph_create_filter(
        &tempo_second, avfilter_get_by_name("atempo"), "tempo_second",
        second_arg.c_str(), nullptr, filter->graph);
    if (result < 0) return result;
  }
  char format_args[160] = {};
  std::snprintf(format_args, sizeof(format_args),
                "sample_fmts=s16:sample_rates=48000:channel_layouts=%s",
                contract.ffmpeg_layout);
  result = avfilter_graph_create_filter(
      &format, avfilter_get_by_name("aformat"), "format", format_args,
      nullptr, filter->graph);
  if (result < 0) return result;
  result = avfilter_graph_create_filter(
      &filter->sink, avfilter_get_by_name("abuffersink"), "output", nullptr,
      nullptr, filter->graph);
  if (result < 0) return result;
  if (tempo) {
    result = avfilter_link(filter->source, 0, tempo, 0);
    if (result < 0) return result;
  }
  if (tempo_second) {
    result = avfilter_link(tempo, 0, tempo_second, 0);
    if (result < 0) return result;
  }
  result = avfilter_link(tempo_second ? tempo_second :
                        tempo ? tempo : filter->source, 0, format, 0);
  if (result < 0) return result;
  result = avfilter_link(format, 0, filter->sink, 0);
  if (result < 0) return result;
  result = avfilter_graph_config(filter->graph, nullptr);
  if (result < 0) return result;
  result = av_channel_layout_copy(&filter->input_layout, &frame->ch_layout);
  if (result < 0) return result;
  filter->input_rate = frame->sample_rate;
  filter->input_format = static_cast<AVSampleFormat>(frame->format);
  filter->speed = speed;
  filter->output_channels = contract.channels;
  filter->output_layout = contract.layout;
  filter->output_delivery = contract.delivery;
  filter->sink_generation = sink_generation;
  filter->media_anchor = media_pts;
  filter->output_anchor = AV_NOPTS_VALUE;
  filter->next_media_pts = media_pts;
  return 0;
}

RillightCoreFrame *convert_audio(const AVFrame *frame, AudioFilter *filter,
                                 uint64_t session, uint64_t timeline) {
  if (frame->format != AV_SAMPLE_FMT_S16 || frame->sample_rate != 48000 ||
      frame->ch_layout.nb_channels != filter->output_channels ||
      frame->nb_samples <= 0 || frame->nb_samples > 480000) return nullptr;
  const int bytes = frame->nb_samples * filter->output_channels * 2;
  auto *output = new (std::nothrow) RillightCoreFrame{};
  if (!output) return nullptr;
  output->data = new (std::nothrow) uint8_t[bytes];
  if (!output->data) {
    delete output;
    return nullptr;
  }
  std::memcpy(output->data, frame->data[0], bytes);
  int64_t pts = filter->next_media_pts;
  if (frame->pts != AV_NOPTS_VALUE && filter->media_anchor != AV_NOPTS_VALUE) {
    const int64_t output_pts = av_rescale_q(
        frame->pts, av_buffersink_get_time_base(filter->sink),
        AVRational{1, 1000000});
    if (filter->output_anchor == AV_NOPTS_VALUE) filter->output_anchor = output_pts;
    pts = filter->media_anchor + static_cast<int64_t>(
                                     (output_pts - filter->output_anchor) *
                                     filter->speed);
  }
  filter->next_media_pts = pts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE :
      pts + static_cast<int64_t>(frame->nb_samples * 1000000.0 /
                                 48000.0 * filter->speed);
  output->struct_size = sizeof(*output);
  output->type = RILLIGHT_CORE_AUDIO_S16;
  output->session_id = session;
  output->timeline_version = timeline;
  output->pts_us = pts == AV_NOPTS_VALUE ? -1 : pts;
  output->sample_rate = 48000;
  output->channels = filter->output_channels;
  output->channel_layout = filter->output_layout;
  output->audio_delivery = filter->output_delivery;
  output->audio_codec_id = 0;
  output->audio_atmos = 0;
  output->sample_count = frame->nb_samples;
  output->data_size = bytes;
  return output;
}

int drain_audio_filter(RillightCoreImpl *core, AudioFilter *filter,
                       int video_index, uint64_t session, uint64_t timeline) {
  if (!filter->graph) return 0;
  AVFrame *filtered = av_frame_alloc();
  if (!filtered) return AVERROR(ENOMEM);
  int result = 0;
  while (!core->stop) {
#if defined(__ANDROID__)
    // A TrueHD access unit can contain only 40 samples. Coalesce into 10 ms
    // PCM blocks so the bounded queue and JNI/AudioTrack feeder do not need
    // 1,200 handoffs per second. get_samples preserves a short final block at
    // EOF; seek/track changes discard the filter with the old timeline.
    result = av_buffersink_get_samples(filter->sink, filtered, 480);
#else
    result = av_buffersink_get_frame(filter->sink, filtered);
#endif
    if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
      result = 0;
      break;
    }
    if (result < 0) break;
    auto *output = convert_audio(filtered, filter, session, timeline);
    av_frame_unref(filtered);
    if (!output) {
      result = AVERROR(EINVAL);
      break;
    }
    result = enqueue(core, output, video_index, timeline);
    if (result < 0) break;
    std::lock_guard lock(core->mutex);
    if (core->timeline != timeline) break;
  }
  av_frame_free(&filtered);
  return result;
}

AudioSinkView audio_sink_view(RillightCoreImpl *core) {
  std::lock_guard lock(core->mutex);
  return {core->sink_max_channels,
          rillight_audio_accept_for_gain(core->sink_accept, core->volume), core->sink_atmos,
          core->speed, core->sink_generation};
}

int packet_passthrough_kind(const AVCodecParameters *parameters,
                            const AVPacket *packet, uint32_t accept,
                            double speed) {
  if (!parameters || !packet || !packet->data || packet->size <= 0)
    return RILLIGHT_CORE_PASSTHROUGH_NONE;
  if (!unity_speed(speed)) return RILLIGHT_CORE_PASSTHROUGH_NONE;
  if (parameters->codec_id == AV_CODEC_ID_TRUEHD &&
      (accept & RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD) != 0)
    return RILLIGHT_CORE_PASSTHROUGH_TRUEHD;
  if (parameters->codec_id == AV_CODEC_ID_EAC3 &&
      (accept & RILLIGHT_CORE_AUDIO_ACCEPT_EAC3) != 0) {
    return parameters->profile == AV_PROFILE_EAC3_DDP_ATMOS ||
           rillight_eac3_frame_is_joc(packet->data, packet->size)
        ? RILLIGHT_CORE_PASSTHROUGH_EAC3_JOC : RILLIGHT_CORE_PASSTHROUGH_EAC3;
  }
  if (parameters->codec_id == AV_CODEC_ID_AC3 &&
      (accept & RILLIGHT_CORE_AUDIO_ACCEPT_AC3) != 0)
    return RILLIGHT_CORE_PASSTHROUGH_AC3;
  if (parameters->codec_id == AV_CODEC_ID_DTS) {
    const bool hd = parameters->profile == AV_PROFILE_DTS_HD_HRA ||
                    parameters->profile == AV_PROFILE_DTS_HD_MA ||
                    parameters->profile == AV_PROFILE_DTS_EXPRESS;
    if (hd && (accept & RILLIGHT_CORE_AUDIO_ACCEPT_DTSHD) != 0)
      return RILLIGHT_CORE_PASSTHROUGH_DTSHD;
    if (!hd && (accept & RILLIGHT_CORE_AUDIO_ACCEPT_DTS) != 0)
      return RILLIGHT_CORE_PASSTHROUGH_DTS;
  }
  return RILLIGHT_CORE_PASSTHROUGH_NONE;
}

RillightCoreFrame *passthrough_frame(const AVPacket *packet,
                                     const AVStream *stream, int kind,
                                     const AudioSinkView &view,
                                     uint64_t session, uint64_t timeline) {
  if (!packet || packet->size <= 0 || !stream || !stream->codecpar)
    return nullptr;
  const auto contract = rillight_audio_contract(
      stream->codecpar->ch_layout.nb_channels, kind, view.max_channels,
      view.accept, view.atmos, view.speed);
  if (!contract.passthrough) return nullptr;
  auto *output = new (std::nothrow) RillightCoreFrame{};
  if (!output) return nullptr;
  output->data = new (std::nothrow) uint8_t[packet->size];
  if (!output->data) {
    delete output;
    return nullptr;
  }
  std::memcpy(output->data, packet->data, static_cast<size_t>(packet->size));
  int64_t pts = -1;
  if (packet->pts != AV_NOPTS_VALUE)
    pts = av_rescale_q(packet->pts, stream->time_base, AVRational{1, 1000000});
  const int sample_rate = stream->codecpar->sample_rate > 0
                              ? stream->codecpar->sample_rate : 48000;
  int sample_count = rillight_passthrough_samples(
      kind, packet->data, packet->size, sample_rate);
  if (sample_count == 0 && packet->duration > 0 && sample_rate > 0) {
    const int64_t scaled = av_rescale_q(packet->duration, stream->time_base,
                                        AVRational{1, sample_rate});
    if (scaled > 0 && scaled <= 480000) sample_count = static_cast<int>(scaled);
  }
  output->struct_size = sizeof(*output);
  output->type = RILLIGHT_CORE_AUDIO_PASSTHROUGH;
  output->session_id = session;
  output->timeline_version = timeline;
  output->pts_us = pts;
  output->sample_rate = sample_rate;
  output->channels = contract.channels;
  output->channel_layout = contract.layout;
  output->audio_codec_id = kind;
  output->audio_delivery = contract.delivery;
  output->audio_atmos = contract.atmos;
  output->sample_count = sample_count;
  output->data_size = packet->size;
  return output;
}
}  // namespace rillight::core
