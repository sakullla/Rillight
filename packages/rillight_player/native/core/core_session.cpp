#include "core_internal.h"
#include "core_lanes.h"
#include "vod_header.h"

namespace rillight::core {

Decoder open_video_decoder(RillightCoreImpl *core, AVFormatContext *format,
                           int index, int64_t discard_before_us) {
  std::shared_ptr<void> window;
  RillightCoreHardware preference = RILLIGHT_CORE_HW_NONE;
  bool allow_software = true;
  uint32_t profiles = 0;
  uint32_t tunnel_profiles = 0;
  std::shared_ptr<AndroidTunnelFactory> tunnel_factory;
  {
    std::lock_guard lock(core->mutex);
#if defined(__ANDROID__)
#endif
    preference = core->hardware_preference;
    allow_software = core->allow_software_fallback;
    profiles = core->android_dovi_profiles.load();
    window = core->android_window;
    if (!core->tunnel_disabled && core->play_intent &&
        core->audio_index >= 0) {
      tunnel_factory = core->tunnel_factory;
      tunnel_profiles = core->tunnel_profiles;
    }
  }
  return make_decoder(format, index, preference, allow_software, window,
                      profiles, discard_before_us, false, tunnel_factory,
                      tunnel_profiles);
}

void run(RillightCoreImpl *core, uint64_t session) {
  AVFormatContext *format = avformat_alloc_context();
  Source *main_source = nullptr;
  Decoder video, audio, subtitle, secondary_subtitle;
  int enhancement_index = -1;
  bool fel_required = false;
  int fel_nal_length = 0;
  AVRational fel_time_base{1, 1000000};
  VideoScale scale;
  PendingPackets pending_packets;
  VideoConvertLane conversion_lane(core);
  AudioFilter audio_filter;
  auto &subtitle_cues = core->subtitle_cues;
  auto &ass = core->ass;
  auto &subtitle_mutex = core->subtitle_mutex;
  { std::lock_guard lock(subtitle_mutex); subtitle_cues.clear(); }
  bool conversion_ready = false;
  VideoSink video_sink = [&](AVFrame *frame, int stream, uint32_t hardware,
                            uint64_t timeline) {
    // Validate the first hardware download synchronously so an unsupported
    // surface can still retry its retained packet with the software decoder.
    // After success, scale and staging buffers belong to the conversion lane.
    if (!conversion_ready) {
      const int result = convert_video_frame(core, format, frame, stream,
          hardware, &scale, &subtitle_cues, &ass, session, timeline,
          &subtitle_mutex);
      if (result >= 0) conversion_ready = true;
      return result;
    }
    return conversion_lane.Push(frame, stream, hardware, timeline);
  };
  DecodeLane video_lane(core, 16u * 1024u * 1024u, RILLIGHT_CORE_VIDEO_RGBA);
  DecodeLane audio_lane(core, 4u * 1024u * 1024u, RILLIGHT_CORE_AUDIO_S16);
  bool passthrough_mode = false;
  DecodeLane subtitle_lane(core, 2u * 1024u * 1024u, 0);
  int result = AVERROR(ENOMEM);
  bool ended = false;
  if (!format) goto finish;
  core->active_read_timeline = core->timeline_signal.load();
  format->opaque = core;
  format->interrupt_callback = AVIOInterruptCB{interrupt_read, core};
  format->io_open = nested_open;
  format->io_close2 = nested_close;

  main_source = open_source(core, core->url.c_str(), AVIO_FLAG_READ);
  if (!main_source) {
    result = core->owned_loopback ? core->owned_loopback->media_open_error.load() : 0;
    if (result >= 0) result = AVERROR(EIO);
    goto finish;
  }
  format->pb = main_source->avio;
  format->flags |= AVFMT_FLAG_CUSTOM_IO;

  result = avformat_open_input(&format, core->url.c_str(), nullptr, nullptr);
  if (result < 0) goto finish;
  // Complete MP4/Matroska VOD headers can open their decoders without reading
  // payloads from every optional track. Incomplete/live headers still probe.
  if (!complete_vod_header(format)) {
    result = avformat_find_stream_info(format, nullptr);
    if (result < 0) goto finish;
  }
  {
    const char *demuxer = format->iformat ? format->iformat->name : nullptr;
    std::lock_guard lock(core->mutex);
    core->source_format_name = demuxer ? demuxer : "";
    core->source_diagnostics =
        "format=" + core->source_format_name + " url=" +
        truncate_for_diagnostics(core->url, 128);
  }

  {
    const int vi = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1,
                                       nullptr, 0);
    const AVCodec *audio_codec = nullptr;
    const int ai = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1,
                                       &audio_codec, 0);
    result = restore_dovi_configuration(format, vi, &pending_packets);
    if (result < 0) goto finish;
    int opened_dovi_profile = RILLIGHT_CORE_DOVI_PROFILE_NONE;
    int opened_dovi_compatibility = -1;
    if (vi >= 0) {
      const auto *parameters = format->streams[vi]->codecpar;
      const auto *dovi = av_packet_side_data_get(
          parameters->coded_side_data, parameters->nb_coded_side_data,
          AV_PKT_DATA_DOVI_CONF);
      if (dovi && dovi->data &&
          dovi->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
        const auto *record =
            reinterpret_cast<const AVDOVIDecoderConfigurationRecord *>(dovi->data);
        opened_dovi_profile = record->dv_profile > 0
            ? record->dv_profile : RILLIGHT_CORE_DOVI_PROFILE_NONE;
        opened_dovi_compatibility = record->dv_bl_signal_compatibility_id;
        if (dovi_open_rejected(record->dv_profile,
                               record->dv_bl_signal_compatibility_id,
                               record->el_present_flag)) {
          result = RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI;
          {
            std::lock_guard lock(core->mutex);
            core->dolby_vision_profile = opened_dovi_profile;
            core->dolby_vision_compatibility = opened_dovi_compatibility;
            core->video_output_kind = RILLIGHT_CORE_VIDEO_OUT_UNKNOWN;
            core->dovi_reconstruction = RILLIGHT_CORE_DOVI_RECON_NONE;
          }
          goto finish;
        }
      }
    }
    {
      std::shared_ptr<void> window;
      void *windows_adapter = nullptr;
      { std::lock_guard lock(core->mutex);
        window = core->android_window;
#if defined(_WIN32)
        windows_adapter = core->dxgi_adapter;
#endif
      }
      video = make_decoder(format, vi, core->hardware_preference,
                           core->allow_software_fallback, window, core->android_dovi_profiles,
                           -1, false, ai >= 0 && core->play_intent ? core->tunnel_factory : nullptr,
                           core->tunnel_profiles, windows_adapter);
    }
    audio = make_decoder(format, ai);
    if ((vi >= 0 && !video.context) || (ai >= 0 && !audio.context)) {
      result = vi >= 0 && !video.context ? video.error : audio.error;
      if (!result) result = AVERROR_DECODER_NOT_FOUND;
      goto finish;
    }
    const int si = av_find_best_stream(format, AVMEDIA_TYPE_SUBTITLE,
                                       -1, -1, nullptr, 0);
    if (si >= 0) {
      const auto codec = format->streams[si]->codecpar->codec_id;
      if (bitmap_subtitle_codec(codec))
        subtitle = make_decoder(format, si);
#if RILLIGHT_HAVE_LIBASS
      else if (codec == AV_CODEC_ID_ASS && open_ass(&ass, format, si))
        subtitle.stream = si;
      else if (text_subtitle_codec(codec)) {
        subtitle = make_decoder(format, si);
        if (!subtitle.context || !open_text_ass(&ass, subtitle.context, si)) {
          avcodec_free_context(&subtitle.context);
          subtitle = {};
        }
      }
#endif
    }
    if (!video.context && !audio.context) {
      result = AVERROR_DECODER_NOT_FOUND;
      goto finish;
    }
    if (video.stream >= 0) {
      const auto* parameters = format->streams[video.stream]->codecpar;
      const auto* dovi = av_packet_side_data_get(parameters->coded_side_data,
          parameters->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
      const auto* record = dovi && dovi->data &&
              dovi->size >= sizeof(AVDOVIDecoderConfigurationRecord)
          ? reinterpret_cast<const AVDOVIDecoderConfigurationRecord*>(dovi->data)
          : nullptr;
      fel_required = record && record->dv_profile == 7 && record->el_present_flag != 0;
      fel_nal_length = rillight_dovi::HevcNalLengthSize(parameters->extradata,
                                                       parameters->extradata_size);
      fel_time_base = format->streams[video.stream]->time_base;
      if (fel_required && !video.android_native_dolby) {
        enhancement_index = find_fel_stream(format, video.stream);
        if (enhancement_index >= 0 &&
            !scale.enhancement.OpenDual(format, enhancement_index))
          enhancement_index = -1;
      }
      scale.enhancement.Configure(fel_required && !video.android_native_dolby,
                                  enhancement_index >= 0, fel_nal_length,
                                  fel_time_base);
    }
    std::lock_guard lock(core->mutex);
    core->decode_diagnostics = video.diagnostics;
    core->dolby_vision_profile = opened_dovi_profile;
    core->dolby_vision_compatibility = opened_dovi_compatibility;
    core->video_index = video.stream;
    core->tunnel = video.tunnel;
    core->android_color_buffers = video.android_color_buffers;
    core->android_native_dolby = video.android_native_dolby;
    const AVRational rate = video.stream >= 0
        ? av_guess_frame_rate(format, format->streams[video.stream], nullptr) : AVRational{0, 1};
    const double source_frame_rate = rate.den > 0 ? av_q2d(rate) : 0;
    core->video_frame_rate = std::isfinite(source_frame_rate) && source_frame_rate > 0 &&
        source_frame_rate <= 240 ? source_frame_rate : 0;


    core->audio_index = audio.stream;
    const char *demuxer = format->iformat ? format->iformat->name : nullptr;
    core->is_mp4_container = demuxer &&
        std::string_view(demuxer).find("mov,mp4") == 0;
    core->video_track_id = core->is_mp4_container && video.stream >= 0 &&
            format->streams[video.stream]->id > 0
        ? format->streams[video.stream]->id : -1;
    core->audio_track_id = core->is_mp4_container && audio.stream >= 0 &&
            format->streams[audio.stream]->id > 0
        ? format->streams[audio.stream]->id : -1;
    core->subtitle_index = subtitle.stream;
    core->duration = format->duration == AV_NOPTS_VALUE ? -1 : format->duration;
    core->media_origin_us = container_origin_us(format);
    core->tracks.clear();
#if RILLIGHT_HAVE_LIBASS
    core->embedded_stream_count = format->nb_streams;
#endif
    for (unsigned int index = 0; index < format->nb_streams; ++index) {
      const auto codec = format->streams[index]->codecpar->codec_id;
      const auto type = format->streams[index]->codecpar->codec_type;
      if (type == AVMEDIA_TYPE_SUBTITLE &&
          !bitmap_subtitle_codec(codec)
#if RILLIGHT_HAVE_LIBASS
          && codec != AV_CODEC_ID_ASS && !text_subtitle_codec(codec)
#endif
          ) continue;
      if (type == AVMEDIA_TYPE_SUBTITLE &&
          (bitmap_subtitle_codec(codec)
#if RILLIGHT_HAVE_LIBASS
           || text_subtitle_codec(codec)
#endif
          ) &&
          !avcodec_find_decoder(codec)) continue;
      auto track = make_track(format->streams[index]);
      if (track.type != 0) core->tracks.push_back(track);
    }
  }
  if (!conversion_lane.Start([&](AVFrame *frame, int stream, uint32_t hardware, uint64_t timeline) {
    return convert_video_frame(core, format, frame, stream, hardware, &scale,
                               &subtitle_cues, &ass, session, timeline, &subtitle_mutex);
  })) { result = AVERROR(ENOMEM); goto finish; }
  if (!video_lane.Start([&](const AVPacket *packet, uint64_t timeline) {
      if (packet && enhancement_index >= 0 &&
          packet->stream_index == enhancement_index) {
        AVPacket* copy = av_packet_clone(packet);
        if (!copy) return AVERROR(ENOMEM);
        scale.enhancement.Feed(copy);
        return 0;
      }

      int result = decode_packet(core, format, video, packet, video.stream,
                             &scale, &audio_filter, &subtitle_cues, &ass,
                             core->external_audio_speed ? 1.0 : core->speed, session,
                             timeline, &subtitle_mutex, &video_sink);
      if (result < 0 && video.hardware != RILLIGHT_CORE_HW_NONE &&
          core->allow_software_fallback) {
        // A configured device can still reject the stream profile when the
        // first packets are decoded. Restart from a keyframe in software;
        // the replacement decoder has no device preference, so this is
        // bounded to one fallback for this stream.
        const bool was_tunneled = !!video.tunnel;
        std::shared_ptr<void> window;
        { std::lock_guard lock(core->mutex); window = core->android_window;
          if (was_tunneled) { core->tunnel.reset(); core->tunnel_disabled = true; } }
        video.tunnel.reset();
        Decoder replacement = was_tunneled
            ? make_decoder(format, video.stream, core->hardware_preference,
                           core->allow_software_fallback, window, core->android_dovi_profiles)
            : make_decoder(format, video.stream);
        if (replacement.context) {
          replacement.diagnostics += "; runtime decoder failure " +
                                     std::to_string(result);
          replacement.hardware_diagnostics = replacement.diagnostics;
          avcodec_free_context(&video.context);
          video = replacement;
          {
            std::lock_guard lock(core->mutex);
            core->decode_diagnostics = video.diagnostics;
            core->android_color_buffers = video.android_color_buffers;
            core->android_native_dolby = video.android_native_dolby;
            for (auto &track : core->tracks) {
              if (track.stream_index == video.stream)
                track.actual_hardware = RILLIGHT_CORE_HW_NONE;
            }
          }
          scale.enhancement.Flush();
          if (fel_required && !video.android_native_dolby) {
            if (enhancement_index < 0) {
              enhancement_index = find_fel_stream(format, video.stream);
              if (enhancement_index >= 0 &&
                  !scale.enhancement.OpenDual(format, enhancement_index))
                enhancement_index = -1;
            }
            scale.enhancement.Configure(true, enhancement_index >= 0,
                                        fel_nal_length, fel_time_base);
          }
          // The hardware may have accepted an entire GOP before rejecting its
          // output format. The failing packet is not a decodable software
          // starting point: retire this timeline and let the demux owner seek
          // back to a keyframe after all lanes have quiesced.
          std::lock_guard lock(core->mutex);
          if (core->timeline == timeline && !core->stop) {
            const int64_t position = playback_position(core);
            ++core->timeline;
            core->timeline_signal = core->timeline;
            reset_frames(core);
            core->seek_target = position;
            core->base_position = position;
            core->base_time = Clock::now();
            core->state = RILLIGHT_CORE_RECOVERING;
            core->wake.notify_all();
            core->io.cancel_media_io(core->io.opaque);
          }
          result = 0;
        }
      }

      return result;
    }) || !audio_lane.Start([&](const AVPacket *packet, uint64_t timeline) {
      const AVCodecParameters *parameters = audio.stream >= 0
          ? format->streams[audio.stream]->codecpar : nullptr;
      const AudioSinkView view = audio_sink_view(core);
      const int kind = packet_passthrough_kind(parameters, packet, view.accept,
                                               view.speed);
      const auto negotiated = rillight_audio_contract(
          parameters ? parameters->ch_layout.nb_channels : 0, kind,
          view.max_channels, view.accept, view.atmos, view.speed);
      // A stereo source stays PCM even when the packet itself is JOC or
      // TrueHD. Rejected passthrough must decode instead of failing the lane.
      const bool want = negotiated.passthrough != 0;
      if (want) {
        if (!passthrough_mode) {
          if (audio.context) avcodec_flush_buffers(audio.context);
          close_audio_filter(&audio_filter);
          passthrough_mode = true;
        }
        auto *output = passthrough_frame(
            packet, format->streams[audio.stream], kind, view, session, timeline);
        if (!output) return AVERROR(ENOMEM);
        const int queued = enqueue(core, output, video.stream, timeline);
        // EAGAIN means speed left 1 or the sink dropped this format while the
        // access unit was being packed. Decode that same packet as PCM.
        if (queued != AVERROR(EAGAIN)) return queued;
      }
      if (passthrough_mode) {
        if (audio.context) avcodec_flush_buffers(audio.context);
        close_audio_filter(&audio_filter);
        passthrough_mode = false;
      }
      int result = decode_packet(core, format, audio, packet, video.stream,
          &scale, &audio_filter, &subtitle_cues, &ass,
          core->external_audio_speed ? 1.0 : core->speed, session, timeline);
      if (result >= 0 && !packet && audio_filter.graph) {
        result = av_buffersrc_add_frame_flags(audio_filter.source, nullptr, 0);
        if (result >= 0) result = drain_audio_filter(core, &audio_filter,
            video.stream, session, timeline);
      }
      return result;
    }) || !subtitle_lane.Start([&](const AVPacket *packet, uint64_t) {
      if (!packet) return 0;
      std::lock_guard lock(subtitle_mutex);
      int result = 0;
      auto &selected_decoder = packet->stream_index == secondary_subtitle.stream
          ? secondary_subtitle : subtitle;
      [[maybe_unused]] auto &selected_ass = packet->stream_index == secondary_subtitle.stream
          ? core->secondary_ass : ass;
      auto &selected_cues = packet->stream_index == secondary_subtitle.stream
          ? core->secondary_cues : subtitle_cues;

      if (selected_decoder.context) {
        const auto codec =
            format->streams[selected_decoder.stream]->codecpar->codec_id;
        if (bitmap_subtitle_codec(codec))
          result = decode_bitmap_subtitle(selected_decoder, packet,
              format->streams[selected_decoder.stream]->time_base, &selected_cues,
              core->media_origin_us,
              video.stream >= 0 ? format->streams[video.stream]->codecpar->width : 0,
              video.stream >= 0 ? format->streams[video.stream]->codecpar->height : 0,
              video.stream >= 0 ? format->streams[video.stream]->codecpar : nullptr);
#if RILLIGHT_HAVE_LIBASS
        else if (text_subtitle_codec(codec) && selected_ass.track)
          result = decode_text_subtitle(selected_decoder, packet,
              format->streams[selected_decoder.stream]->time_base, &selected_ass,
              core->media_origin_us);
#endif
      }
#if RILLIGHT_HAVE_LIBASS
      else if (selected_ass.track)
        process_ass(&selected_ass, packet,
                    format->streams[selected_decoder.stream]->time_base,
                    core->media_origin_us);
#endif

      return result;
    })) { result = AVERROR(ENOMEM); goto finish; }

  while (!core->stop) {
    uint64_t timeline;
    int64_t seek;
    int selected_audio;
    bool change_audio;
    bool change_subtitle;
    int selected_subtitle;
    int selected_subtitle_slot;
    bool change_speed;
    double selected_speed;
    {
      std::unique_lock lock(core->mutex);
      // A paused timeline only needs its first frame. Keep the decoder asleep
      // after that frame instead of filling both output queues while the
      // surface and audio device are idle. A seek resets first_* and changes
      // the timeline, so it can decode a fresh preview before sleeping again.
      core->wake.wait(lock, [&] {
        // A detached Android Surface is a presentation interruption. Do not
        // reopen MediaCodec in byte-buffer mode while the replacement view is
        // being mounted; that would discard the HDR path and can terminate
        // the current seek before the new Surface arrives.
        if (core->hardware_preference == RILLIGHT_CORE_HW_MEDIACODEC &&
            video.stream >= 0 && !core->android_window)
          return core->stop || core->decode_abort;
        return core->stop || core->decode_abort || core->play_intent ||
               core->seek_target >= 0 || core->audio_change ||
               core->subtitle_change || core->speed_change ||
               !(video.stream >= 0 ? core->first_video : core->first_audio);
      });
      if (core->stop || core->decode_abort) break;
      timeline = core->timeline;
      seek = core->seek_target;
      core->seek_target = -1;
      change_audio = core->audio_change;
      selected_audio = core->requested_audio;
      core->audio_change = false;
      change_subtitle = core->subtitle_change;
      selected_subtitle = core->requested_subtitle;
      selected_subtitle_slot = core->requested_subtitle_slot;
      core->subtitle_change = false;
      change_speed = core->speed_change;
      selected_speed = core->requested_speed;
      core->speed_change = false;
    }
    core->active_read_timeline = timeline;
    const bool subtitle_off_only = change_subtitle && selected_subtitle == -1 &&
        seek < 0 && !change_audio && !change_speed;
    const bool reconfigure = seek >= 0 || change_audio || change_subtitle ||
        change_speed;
    if (reconfigure) {
      if (!subtitle_off_only) {
        video_lane.Quiesce();
        conversion_lane.Quiesce();
        audio_lane.Quiesce();
      }
      subtitle_lane.Quiesce();
    }
    if (seek >= 0) {
      {
        std::lock_guard lock(core->mutex);
        if (core->timeline != timeline) continue;
        core->presentation_floor_us = seek;
        core->media_io_active = true;
      }
      if (format->pb) {
        format->pb->error = 0;
        format->pb->eof_reached = 0;
      }
      pending_packets.Clear();
      int64_t seek_ts = seek;
      const int64_t origin = core->media_origin_us > 0
          ? core->media_origin_us
          : container_origin_us(format);
      if (origin > 0 &&
          seek <= std::numeric_limits<int64_t>::max() - origin) {
        seek_ts = seek + origin;
      }
      result = av_seek_frame(format, -1, seek_ts, AVSEEK_FLAG_BACKWARD);
      {
        std::lock_guard lock(core->mutex);
        core->media_io_active = false;
        if (core->timeline != timeline) {
          if (format->pb) {
            format->pb->error = 0;
            format->pb->eof_reached = 0;
          }
          continue;
        }
      }
      if (result < 0) break;
      bool software_required = false;
      { std::lock_guard lock(core->mutex); software_required = core->software_video_required; }
      if (video.context && software_required &&
          (video.hardware != RILLIGHT_CORE_HW_NONE)) {
        Decoder replacement = make_decoder(format, video.stream);
        if (!replacement.context) {
          result = replacement.error < 0 ? replacement.error : AVERROR_DECODER_NOT_FOUND;
          break;
        }
        avcodec_free_context(&video.context);
        replacement.diagnostics += "; presentation requires software";
        video = replacement;
        conversion_ready = false;
        std::lock_guard lock(core->mutex);
        core->decode_diagnostics = video.diagnostics;
        core->android_color_buffers = false;
        core->android_native_dolby = false;
        core->tunnel.reset();
        for (auto& track : core->tracks)
          if (track.stream_index == video.stream) track.actual_hardware = RILLIGHT_CORE_HW_NONE;
      } else if (video.context && (video.hardware == RILLIGHT_CORE_HW_MEDIACODEC &&
           (!video.android_color_buffers || video.android_dovi_surface))) {
        // Some Android Codec2 implementations stop producing pictures after
        // flush during an audio/subtitle/rate seek. All decode/conversion lanes
        // are quiescent here, so retire the codec and create a fresh instance.
        const int stream = video.stream;
        { std::lock_guard lock(core->mutex); core->tunnel.reset(); }
        video.tunnel.reset();
        avcodec_free_context(&video.context);
        video = open_video_decoder(core, format, stream,
                                   std::max<int64_t>(0, seek - 5000));
        if (!video.context) {
          result = video.error < 0 ? video.error : AVERROR_DECODER_NOT_FOUND;
          break;
        }
        conversion_ready = false;
        std::lock_guard lock(core->mutex);
        core->decode_diagnostics = video.diagnostics;
        core->android_color_buffers = video.android_color_buffers;
        core->android_native_dolby = video.android_native_dolby;
        core->tunnel = video.tunnel;
        for (auto& track : core->tracks) {
          if (track.stream_index == stream)
            track.actual_hardware = RILLIGHT_CORE_HW_NONE;
        }
      } else if (video.context) {
        if (video.android_color_buffers) {
          // Byte output owns its pixels; no outstanding decoder Surface buffers
          // delay flushing. Preserve parameter sets learned from in-band HEVC,
          // and update the preroll cutoff in both directions on every seek.
          result = av_opt_set_int(video.context->priv_data, "discard_before",
                                   std::max<int64_t>(0, seek - 5000), 0);
          if (result < 0) break;
        }
        avcodec_flush_buffers(video.context);
      }
      scale.enhancement.Flush();
      if (audio.context) avcodec_flush_buffers(audio.context);
      audio.dts_recovery.reset();
      if (subtitle.context) avcodec_flush_buffers(subtitle.context);
      if (secondary_subtitle.context) avcodec_flush_buffers(secondary_subtitle.context);
      close_audio_filter(&audio_filter);
      std::lock_guard subtitle_lock(subtitle_mutex);
      subtitle_cues.clear();
      core->secondary_cues.clear();
#if RILLIGHT_HAVE_LIBASS
      if (core->secondary_ass.track && !core->secondary_ass.external)
        ass_flush_events(core->secondary_ass.track);
      if (ass.track && !ass.external) ass_flush_events(ass.track);
#endif
    }
    if (change_audio) {
      Decoder replacement = make_decoder(format, selected_audio);
      if (replacement.context &&
          format->streams[selected_audio]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
        avcodec_free_context(&audio.context);
        audio = replacement;
        close_audio_filter(&audio_filter);
        std::lock_guard lock(core->mutex);
        core->audio_index = selected_audio;
        core->audio_track_id = core->is_mp4_container &&
                format->streams[selected_audio]->id > 0
            ? format->streams[selected_audio]->id : -1;
        core->error = 0;
      } else {
        avcodec_free_context(&replacement.context);
        std::lock_guard lock(core->mutex);
        core->error = replacement.error < 0 ? replacement.error :
                                                AVERROR_DECODER_NOT_FOUND;
      }
    }
    if (change_subtitle) {
      Decoder &primary_subtitle = subtitle;
      auto &subtitle = selected_subtitle_slot == 1 ? secondary_subtitle : primary_subtitle;
      auto &ass = selected_subtitle_slot == 1 ? core->secondary_ass : core->ass;
      auto &subtitle_cues = selected_subtitle_slot == 1 ? core->secondary_cues : core->subtitle_cues;
      Decoder replacement;
      bool ass_selected = false;
#if RILLIGHT_HAVE_LIBASS
      AssRenderer replacement_ass;
#endif
      if (selected_subtitle >= 0 &&
          selected_subtitle < static_cast<int>(format->nb_streams) &&
          format->streams[selected_subtitle]->codecpar->codec_type ==
              AVMEDIA_TYPE_SUBTITLE) {
        const auto codec =
            format->streams[selected_subtitle]->codecpar->codec_id;
        if (bitmap_subtitle_codec(codec))
          replacement = make_decoder(format, selected_subtitle);
#if RILLIGHT_HAVE_LIBASS
        else if (codec == AV_CODEC_ID_ASS &&
                 open_ass(&replacement_ass, format, selected_subtitle)) {
          replacement.stream = selected_subtitle;
          ass_selected = true;
        }
        else if (text_subtitle_codec(codec)) {
          replacement = make_decoder(format, selected_subtitle);
          if (replacement.context &&
              open_text_ass(&replacement_ass, replacement.context,
                            selected_subtitle))
            ass_selected = true;
          else {
            avcodec_free_context(&replacement.context);
            replacement = {};
          }
        }
#endif
      }
#if RILLIGHT_HAVE_LIBASS
      if (!replacement.context && !ass_selected) {
        std::shared_ptr<const std::vector<char>> script;
        std::shared_ptr<const std::vector<ExternalTextCue>> cues;
        AVCodecID external_codec = AV_CODEC_ID_NONE;
        {
          std::lock_guard lock(core->mutex);
          for (const auto &external : core->external_subtitles) {
            if (external.stream_index == selected_subtitle) {
              script = external.script;
              cues = external.cues;
              external_codec = external.codec;
              break;
            }
          }
        }
        const bool opened = script &&
            (external_codec == AV_CODEC_ID_ASS ?
             open_external_ass(&replacement_ass, *script,
                               selected_subtitle) :
             cues && open_external_text(&replacement_ass, *script, *cues,
                                         selected_subtitle));
        if (opened) {
          replacement.stream = selected_subtitle;
          ass_selected = true;
        }
      }
#endif
      if (selected_subtitle == -1 || replacement.context || ass_selected) {
        avcodec_free_context(&subtitle.context);
        subtitle = replacement;
        {
        std::lock_guard subtitle_lock(subtitle_mutex);
        subtitle_cues.clear();
        close_ass(&ass);
#if RILLIGHT_HAVE_LIBASS
        if (ass_selected) {
          ass = replacement_ass;
          // Only plain text has a default slot position. ASS authored layout
          // is preserved. Style fields already hold libass's internal encoding
          // (numpad values are converted while parsing), so top center is
          // HALIGN_CENTER | VALIGN_TOP, not the numpad value 8.
          if (selected_subtitle_slot == 1 && ass.plain_text)
            for (int i = 0; i < ass.track->n_styles; ++i)
              ass.track->styles[i].Alignment = HALIGN_CENTER | VALIGN_TOP;
        }
#endif
        }
        std::lock_guard lock(core->mutex);
        (selected_subtitle_slot == 1 ? core->secondary_subtitle_index : core->subtitle_index) = subtitle.stream;
        core->error = 0;
      } else {
        std::lock_guard lock(core->mutex);
        core->error = AVERROR_DECODER_NOT_FOUND;
      }
      { std::lock_guard lock(core->mutex); core->subtitle_selection_pending = false; }
    }
    if (change_speed) {
      close_audio_filter(&audio_filter);
      std::lock_guard lock(core->mutex);
      core->speed = selected_speed;
    }
    // Do not seek/read the payload of every unselected MP4 audio track.
    // Keep their headers and indices so a later selection can re-enable them.
    for (unsigned i = 0; i < format->nb_streams; ++i) {
      format->streams[i]->discard =
          static_cast<int>(i) == video.stream ||
          static_cast<int>(i) == audio.stream ||
          static_cast<int>(i) == subtitle.stream ||
          static_cast<int>(i) == secondary_subtitle.stream
              ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
    }
    conversion_lane.Resume();
    video_lane.Resume();
    audio_lane.Resume();
    subtitle_lane.Resume();
    AVPacket *packet = av_packet_alloc();
    if (!packet) { result = AVERROR(ENOMEM); break; }
    {
      std::lock_guard lock(core->mutex);
      if (core->timeline != timeline) {
        av_packet_free(&packet);
        continue;
      }
      core->media_io_active = true;
    }
    if (!pending_packets.values.empty()) {
      AVPacket* saved = pending_packets.values.front();
      pending_packets.values.pop_front();
      av_packet_move_ref(packet, saved);
      av_packet_free(&saved);
      result = 0;
    } else result = av_read_frame(format, packet);
    {
      std::lock_guard lock(core->mutex);
      core->media_io_active = false;
      if (core->timeline != timeline) {
        av_packet_free(&packet);
        if (format->pb) {
          format->pb->error = 0;
          format->pb->eof_reached = 0;
        }
        continue;
      }
    }
    if (core->decode_abort) { av_packet_free(&packet); break; }
    const int fatal_io_error = core->io_fatal_error.load();
    if (fatal_io_error < 0) {
      av_packet_free(&packet);
      result = fatal_io_error;
      break;
    }
    if (result == AVERROR(EAGAIN)) {
      av_packet_free(&packet);
      {
        std::lock_guard lock(core->mutex);
        // A stalled demuxer must not freeze frames already queued for future
        // presentation. Otherwise their deadlines can never be reached, and
        // no new decoded frame may arrive to resume the playback clock.
        const int64_t position = playback_position(core);
        if (core->state == RILLIGHT_CORE_PLAYING && core->video.empty() &&
            core->audio.empty() &&
            (!core->audio_clock_active || position >= core->audio_clock_limit)) {
          core->base_position = position;
          core->base_time = Clock::now();
          core->state = RILLIGHT_CORE_BUFFERING;
        }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
      continue;
    }
    if (result == AVERROR_EOF) {
      av_packet_free(&packet);
      {
        std::lock_guard lock(core->mutex);
        if (core->timeline != timeline) continue;
        // Decoder queues may still contain seconds of data. Keep track and
        // subtitle commands available until both lanes have drained.
      }
      result = video_lane.Push(nullptr, timeline);
      if (result >= 0) result = audio_lane.Push(nullptr, timeline);
      if (result < 0) break;
      video_lane.Drain(timeline);
      conversion_lane.Drain(timeline);
      audio_lane.Drain(timeline);
      subtitle_lane.Drain(timeline);
      if (core->decode_abort) { result = core->decode_error.load(); break; }
      std::unique_lock lock(core->mutex);
      if (core->timeline != timeline) continue;
      core->input_exhausted = true;
      core->eof = true;
      core->wake.wait(lock, [&] {
        return core->stop || core->timeline != timeline ||
               (core->video.empty() && core->audio.empty() &&
                core->output_drained);
      });
      if (core->stop) break;
      if (core->timeline != timeline) continue;
      ended = true;
      result = 0;
      break;
    }
    if (result < 0) { av_packet_free(&packet); break; }
    if (packet->stream_index == video.stream ||
        (enhancement_index >= 0 && packet->stream_index == enhancement_index))
      result = video_lane.Push(packet, timeline);
    else if (packet->stream_index == audio.stream)
      result = audio_lane.Push(packet, timeline);
    else if (packet->stream_index == subtitle.stream ||
             packet->stream_index == secondary_subtitle.stream)
      result = subtitle_lane.Push(packet, timeline);
    else result = 0;
    av_packet_free(&packet);
    if (result < 0) break;
  }
finish:

  core->decode_abort = true;
  core->wake.notify_all();
  video_lane.Stop();
  conversion_lane.Stop();
  audio_lane.Stop();
  subtitle_lane.Stop();
  if (core->decode_error < 0) result = core->decode_error.load();
  // The last displayed clean frame outlives decoding (including EOF). Keep its
  // subtitle events/fonts until the session is replaced or destroyed so a
  // paused viewport/PiP redraw cannot erase still-active glyphs.
  close_audio_filter(&audio_filter);
  { std::lock_guard lock(core->mutex); core->tunnel.reset(); }
  video.tunnel.reset();
  avcodec_free_context(&video.context);
  avcodec_free_context(&audio.context);
  avcodec_free_context(&subtitle.context);
  avcodec_free_context(&secondary_subtitle.context);
  if (format) avformat_close_input(&format);
  close_source(main_source);
  std::lock_guard lock(core->mutex);
  if (!core->stop && core->session == session) {
    core->error = ended ? 0 : (result < 0 ? result : AVERROR_UNKNOWN);
    core->state = ended ? RILLIGHT_CORE_ENDED : RILLIGHT_CORE_FAILED;
    if (!ended) {
      if (!video.diagnostics.empty())
        core->decode_diagnostics = video.diagnostics;
      core->source_diagnostics =
          "format=" + core->source_format_name +
          " err=" + std::to_string(core->error) +
          " io=" + std::to_string(core->io_fatal_error.load()) +
          " url=" + truncate_for_diagnostics(core->url, 128);
    }
  }
  core->wake.notify_all();
}

void stop_worker(RillightCoreImpl *core) {
  core->stop = true;
  core->wake.notify_all();
  if ((core->worker.joinable() || core->subtitle_loader.joinable()) &&
      core->io.cancel) core->io.cancel(core->io.opaque);
  if (core->worker.joinable()) core->worker.join();
  if (core->subtitle_loader.joinable()) core->subtitle_loader.join();
}
}  // namespace rillight::core
