#include "core_internal.h"

namespace rillight::core {
int decode_tunnel_packet(RillightCoreImpl* core, Decoder& decoder,
                         const AVPacket* packet, uint64_t timeline) {
  auto tunnel = decoder.tunnel;
  auto submit = [&](const uint8_t* data, int size, int64_t pts) {
    const auto started = Clock::now();
    for (;;) {
      {
        std::unique_lock lock(core->mutex);
        if (core->stop || core->decode_abort || core->timeline != timeline) return 0;
        if ((!core->play_intent && core->first_video) ||
            (pts > playback_position(core) + 750000 && core->first_audio)) {
          core->wake.wait_for(lock, std::chrono::milliseconds(4));
          continue;
        }
      }
      std::shared_ptr<AndroidTunnelSink> sink;
      { std::lock_guard lock(tunnel->mutex); sink = tunnel->sink; }
      if (!sink) return AVERROR(EIO);
      const int accepted = sink->Queue(data, size, pts);
      if (accepted < 0) return AVERROR(EIO);
      if (accepted > 0) {
        if (data) tunnel->submitted = std::max(tunnel->submitted.load(), pts);
        return 0;
      }
      // Never leave stop/seek waiting inside a blocking MediaCodec queue call.
      // A paused audio clock is intentional backpressure, not a decoder error.
      { std::lock_guard lock(core->mutex);
        if (core->play_intent && Clock::now() - started > std::chrono::seconds(8))
          return AVERROR(ETIMEDOUT); }
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
  };
  if (!packet) return submit(nullptr, 0, std::max<int64_t>(0, tunnel->submitted));
  AVPacket* filtered = av_packet_clone(packet);
  if (!filtered) return AVERROR(ENOMEM);
  int result = av_bsf_send_packet(tunnel->filter, filtered);
  if (result < 0) { av_packet_free(&filtered); return result; }
  while ((result = av_bsf_receive_packet(tunnel->filter, filtered)) >= 0) {
    if (tunnel->csd.empty()) {
      // Some remuxes carry parameter sets only in the first Annex-B access unit.
      // Preserve complete start-code-prefixed VPS/SPS/PPS, never an RPU as CSD.
      std::vector<int> starts;
      for (int i = 0; i + 4 < filtered->size; ++i) {
        if (!filtered->data[i] && !filtered->data[i+1] &&
            filtered->data[i+2] == 1) starts.push_back(i);
      }
      for (size_t i = 0; i < starts.size(); ++i) {
        const int start = starts[i];
        const int end = i + 1 < starts.size() ? starts[i+1] : filtered->size;
        const int type = (filtered->data[start+3] >> 1) & 63;
        if (type >= 32 && type <= 34)
          tunnel->csd.insert(tunnel->csd.end(), filtered->data + start, filtered->data + end);
      }
    }
    {
      std::lock_guard lock(tunnel->mutex);
      if (!tunnel->sink && !tunnel->csd.empty())
        tunnel->sink = tunnel->factory->Open(tunnel->window.get(), tunnel->width,
            tunnel->height, tunnel->profile, tunnel->level, tunnel->csd,
            tunnel->config, tunnel->rate);
      if (!tunnel->sink) { result = AVERROR(EIO); break; }
    }
    const int64_t pts = filtered->pts != AV_NOPTS_VALUE ? filtered->pts : filtered->dts;
    if (pts == AV_NOPTS_VALUE) { result = AVERROR_INVALIDDATA; break; }
    result = submit(filtered->data, filtered->size,
        av_rescale_q(pts, tunnel->time_base, AVRational{1, 1000000}));
    av_packet_unref(filtered);
    if (result < 0 || core->timeline_signal != timeline) break;
  }
  av_packet_free(&filtered);
  return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}

int decode_packet(RillightCoreImpl *core, AVFormatContext *format,
                  Decoder &decoder, const AVPacket *packet, int video_index,
                  VideoScale *scale, AudioFilter *audio_filter,
                  std::vector<SubtitleCue> *cues, AssRenderer *ass,
                  double speed,
                  uint64_t session, uint64_t timeline, std::mutex *subtitle_mutex,
                  const VideoSink *video_sink) {
  if (decoder.tunnel) return decode_tunnel_packet(core, decoder, packet, timeline);
  if (!decoder.context) return 0;
  const auto recover_dts_packet = [&](int error) {
    return error == AVERROR_INVALIDDATA && packet && packet->size > 0 &&
        decoder.context->codec_id == AV_CODEC_ID_DTS &&
        decoder.dts_recovery.skipInvalidPacket();
  };
  const auto non_picture_error = [&](int error) {
    const auto* context = decoder.context;
    if (error != AVERROR_INVALIDDATA || !packet || packet->size <= 0 ||
        context->codec_id != AV_CODEC_ID_H264) return false;
    const int nal_length = context->extradata_size >= 5 && context->extradata[0] == 1
        ? (context->extradata[4] & 3) + 1 : 0;
    return rillight_h264_non_picture(packet->data,
                                    static_cast<size_t>(packet->size), nal_length);
  };

  if (scale && decoder.stream == video_index && scale->enhancement.enabled &&
      !scale->enhancement.dual) {
    if (!packet) {
      scale->enhancement.Feed(nullptr);
    } else if (packet->data && packet->size > 0) {
      std::vector<uint8_t> enhancement_bytes;
      const int nal_length = scale->enhancement.nal_length_size;
      bool enhancement_framed = false;
      if (nal_length > 0) {
        enhancement_framed = rillight_dovi::ExtractInterleavedEnhancement(
            packet->data, static_cast<size_t>(packet->size), nal_length,
            &enhancement_bytes);
      }
      if (!enhancement_framed) {
        enhancement_framed = rillight_dovi::ExtractInterleavedEnhancement(
            packet->data, static_cast<size_t>(packet->size), 0, &enhancement_bytes);
      }
      if (enhancement_framed &&
          !enhancement_bytes.empty() &&
          enhancement_bytes.size() <= static_cast<size_t>(std::numeric_limits<int>::max())) {
        AVPacket* enhancement_packet = av_packet_alloc();
        if (enhancement_packet &&
            av_new_packet(enhancement_packet, static_cast<int>(enhancement_bytes.size())) >= 0) {
          std::memcpy(enhancement_packet->data, enhancement_bytes.data(), enhancement_bytes.size());
          enhancement_packet->pts = packet->pts;
          enhancement_packet->duration = packet->duration;
          scale->enhancement.Feed(enhancement_packet);
        } else {
          av_packet_free(&enhancement_packet);
        }
      }
    }
  }
  int result = avcodec_send_packet(decoder.context, packet);
  if (recover_dts_packet(result)) return 0;
  if (non_picture_error(result)) return 0;
  bool submitted = result != AVERROR(EAGAIN);
  if (result < 0 && submitted) return result;
  AVFrame *decoded = av_frame_alloc();
  if (!decoded) return AVERROR(ENOMEM);
  while (!core->stop && !core->decode_abort) {
    result = avcodec_receive_frame(decoder.context, decoded);
    if (result == AVERROR(EAGAIN) && !submitted) {
      // Backpressure is not a failed hardware decoder. Retain the packet,
      // drain output, and retry rather than replacing MediaCodec in software.
      { std::lock_guard lock(core->mutex); if (core->timeline != timeline) break; }
      result = avcodec_send_packet(decoder.context, packet);
      if (recover_dts_packet(result)) { result = 0; break; }
      if (non_picture_error(result)) { result = 0; break; }
      submitted = result != AVERROR(EAGAIN);
      if (result < 0 && submitted) break;
      if (!submitted) std::this_thread::sleep_for(std::chrono::milliseconds(1));
      continue;
    }
    if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) break;
    if (recover_dts_packet(result)) { result = 0; break; }
    if (result < 0) break;
    decoder.dts_recovery.reset();
    const int64_t pts = media_pts_us(
        core, frame_time(decoded, format->streams[decoder.stream]));
    if (decoder.stream == video_index) {
      update_decode_diagnostics(core, decoder, decoded);
#if defined(__ANDROID__)
      if (decoder.android_dovi_surface &&
          !decoder.android_dovi_surface->Attach(decoded, decoder.android_dovi_surface)) {
        result = AVERROR(ENOMEM);
        break;
      }
#endif
      result = video_sink
          ? (*video_sink)(decoded, decoder.stream, decoder.hardware, timeline)
          : convert_video_frame(core, format, decoded, decoder.stream,
                                decoder.hardware, scale, cues, ass,
                                session, timeline, subtitle_mutex);
      av_frame_unref(decoded);
      if (result < 0) break;
    } else {
      // Codec priming commonly gives the first audio frame a negative PTS.
      // Keep that valid anchor distinct from missing timestamps; otherwise
      // every filtered frame inherits "unknown" and seeking plays old audio
      // while the video clock runs ahead and discards all following pictures.
      const int64_t audio_pts = decoded->best_effort_timestamp == AV_NOPTS_VALUE
                                    ? AV_NOPTS_VALUE : pts;
      int max_channels = 2;
      int reports_atmos = 0;
      uint64_t generation = 0;
      {
        std::lock_guard lock(core->mutex);
        max_channels = core->sink_max_channels;
        reports_atmos = core->sink_atmos;
        generation = core->sink_generation;
      }
      const auto contract = rillight_audio_contract(
          decoded->ch_layout.nb_channels, RILLIGHT_CORE_PASSTHROUGH_NONE,
          max_channels, 0, reports_atmos, speed);
      result = prepare_audio_filter(audio_filter, decoded, speed, audio_pts,
                                    contract, generation);
      decoded->pts = audio_pts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE :
          av_rescale_q(audio_pts, AVRational{1, 1000000},
                       AVRational{1, decoded->sample_rate});
      if (result >= 0)
        result = av_buffersrc_add_frame_flags(audio_filter->source, decoded,
                                               AV_BUFFERSRC_FLAG_KEEP_REF);
      av_frame_unref(decoded);
      if (result < 0) break;
      result = drain_audio_filter(core, audio_filter, video_index, session,
                                  timeline);
      if (result < 0) break;
    }
    std::lock_guard lock(core->mutex);
    if (core->timeline != timeline) break;
  }
  av_frame_free(&decoded);
  if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) return 0;
  return result < 0 ? result : 0;
}

}  // namespace rillight::core
