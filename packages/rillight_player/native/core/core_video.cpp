#include "core_video.h"
#include "core_state.h"

namespace rillight::core {
int64_t frame_time(const AVFrame *frame, const AVStream *stream) {
  if (frame->best_effort_timestamp == AV_NOPTS_VALUE) return -1;
  return av_rescale_q(frame->best_effort_timestamp, stream->time_base,
                      AVRational{1, 1000000});
}

int64_t media_pts_us(const RillightCoreImpl *core, int64_t pts_us) {
  if (!core || pts_us < 0 || core->media_origin_us <= 0) return pts_us;
  return pts_us - core->media_origin_us;
}

// format->start_time is often unset for HLS/MPEG-TS. A stream start still
// names the same absolute clock the packet PTS uses.
int64_t container_origin_us(const AVFormatContext *format) {
  if (!format) return 0;
  if (format->start_time != AV_NOPTS_VALUE && format->start_time > 0)
    return format->start_time;
  int64_t origin = 0;
  for (unsigned int index = 0; index < format->nb_streams; ++index) {
    const AVStream *stream = format->streams[index];
    if (!stream || stream->start_time == AV_NOPTS_VALUE ||
        stream->start_time <= 0)
      continue;
    const int64_t us = av_rescale_q(
        stream->start_time, stream->time_base, AVRational{1, 1000000});
    if (us > 0 && (origin == 0 || us < origin)) origin = us;
  }
  return origin;
}

// Samples more than a few seconds past the program are still on the MPEG-TS
// clock. Adopting one as base_position jumps the seek bar to the end and,
// once that adoption is refused, the picture is never released.
constexpr int64_t kAbsolutePtsSlackUs = 5LL * 1000000;

void rebase_absolute_program_pts(RillightCoreImpl *core,
                                 RillightCoreFrame *frame) {
  const int64_t pts = frame->pts_us;
  const int64_t duration = core->duration;
  if (pts < 0 || duration <= 0 || pts <= duration + kAbsolutePtsSlackUs)
    return;
  if (core->media_origin_us <= 0) {
    // A resume seek is already past the program start. That picture is not
    // the origin. From-zero playback, including transcode HLS, is.
    if (core->presentation_floor_us > 0) return;
    core->media_origin_us = pts;
    frame->pts_us = 0;
    return;
  }
  if (pts + duration >= core->media_origin_us)
    frame->pts_us = pts - core->media_origin_us;
}

RillightCoreFrame *convert_video(const AVFrame *frame, int64_t pts,
                                 uint64_t session, uint64_t timeline,
                                 const AVStream *stream,
                                 VideoScale *scale, int output_width,
                                 int output_height, bool gpu_video,
                                 bool hdr_video,
                                 bool macos_edr,
                                 const AVFrame *enhancement,
                                 int *convert_error,
                                 bool linear_cpu) {
  if (frame->width <= 0 || frame->height <= 0 ||
      frame->width > static_cast<int>(kMaxVideoBytes / 4))
    return nullptr;
  const AVPacketSideData *dovi = av_packet_side_data_get(
      stream->codecpar->coded_side_data, stream->codecpar->nb_coded_side_data,
      AV_PKT_DATA_DOVI_CONF);
  const bool tagged_dovi = stream->codecpar->codec_tag == MKTAG('d','v','h','1') ||
      stream->codecpar->codec_tag == MKTAG('d','v','h','e');
  const AVDOVIDecoderConfigurationRecord *record =
      dovi && dovi->data && dovi->size >= sizeof(AVDOVIDecoderConfigurationRecord)
          ? reinterpret_cast<const AVDOVIDecoderConfigurationRecord *>(dovi->data)
          : nullptr;
  rillight_color::Constants dovi_scratch{};
  const bool rpu_usable = rillight_color::DoviConstants(frame, &dovi_scratch, true);
  bool residual = false;
  if (const auto *side = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA);
      side && side->data && side->size >= sizeof(AVDOVIMetadata)) {
    const auto *metadata = reinterpret_cast<const AVDOVIMetadata *>(side->data);
    if (metadata->header_offset <= side->size &&
        sizeof(AVDOVIRpuDataHeader) <= side->size - metadata->header_offset)
      residual = av_dovi_get_header(metadata)->disable_residual_flag == 0;
  }
  struct AvFrameDeleter {
    void operator()(AVFrame *frame) const {
      AVFrame *local = frame;
      av_frame_free(&local);
    }
  };
  std::unique_ptr<AVFrame, AvFrameDeleter> downloaded;
  const AVFrame* compose_base = frame;
  if (residual && enhancement && rpu_usable && frame->hw_frames_ctx) {
    downloaded.reset(av_frame_alloc());
    if (!downloaded || av_hwframe_transfer_data(downloaded.get(), frame, 0) < 0 ||
        av_frame_copy_props(downloaded.get(), frame) < 0)
      downloaded.reset();
    else
      compose_base = downloaded.get();
  }
  // Residual stays out of the base codes. The mapper reshapes the original
  // base and adds the normalized NLQ afterwards.
  rillight_color::FelResidual fel{};
  const AVFrame* fel_source = nullptr;
  int composed_ok = 0;
  if (residual && enhancement && rpu_usable && compose_base &&
      !compose_base->hw_frames_ctx &&
      rillight_color::LoadFelResidual(compose_base, enhancement, &fel) &&
      fel.differs) {
    composed_ok = 1;
    fel_source = enhancement;
  }
  const int profile = record ? record->dv_profile : tagged_dovi ? 5 : -1;
  const int compatibility = record ? record->dv_bl_signal_compatibility_id : 0;
  const int el_present = record ? record->el_present_flag : 0;
  DoviFrameDecision dovi_decision = dovi_frame_decision(
      profile, compatibility, el_present, rpu_usable ? 1 : 0, residual ? 1 : 0,
      composed_ok);
  if (!record && tagged_dovi && !rpu_usable) {
    dovi_decision.error = RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI;
    dovi_decision.emit_picture = 0;
    dovi_decision.use_rpu = 0;
  }
  if (dovi_decision.error || !dovi_decision.emit_picture) {
    if (convert_error)
      *convert_error = dovi_decision.error
                           ? dovi_decision.error
                           : RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI;
    return nullptr;
  }
  int reconstruction = dovi_decision.reconstruction;
  const AVFrame *picture = frame;
  if (reconstruction == RILLIGHT_CORE_DOVI_RECON_FEL && fel_source)
    picture = compose_base;
  else
    fel_source = nullptr;
  const bool base_allowed = profile == 7 || profile == 8;
  AVRational sar = frame->sample_aspect_ratio;
  if (sar.num <= 0 || sar.den <= 0) sar = stream->sample_aspect_ratio;
  if (sar.num <= 0 || sar.den <= 0)
    sar = stream->codecpar->sample_aspect_ratio;
  if (sar.num <= 0 || sar.den <= 0) sar = AVRational{1, 1};
  int width = frame->width;
  int height = frame->height;
  if (output_width > 0 && output_height > 0) {
    const auto* matrix = av_frame_get_side_data(frame, AV_FRAME_DATA_DISPLAYMATRIX);
    const auto* stream_matrix = av_packet_side_data_get(
        stream->codecpar->coded_side_data, stream->codecpar->nb_coded_side_data,
        AV_PKT_DATA_DISPLAYMATRIX);
    const int32_t* rotation = matrix && matrix->size >= 9 * sizeof(int32_t)
        ? reinterpret_cast<const int32_t*>(matrix->data)
        : stream_matrix && stream_matrix->size >= 9 * sizeof(int32_t)
        ? reinterpret_cast<const int32_t*>(stream_matrix->data) : nullptr;
    if (rotation && std::abs(static_cast<int64_t>(rotation[1])) >
                        std::abs(static_cast<int64_t>(rotation[0])))
      std::swap(output_width, output_height);
    const double factor = std::min({1.0,
        output_width / (frame->width * av_q2d(sar)),
        static_cast<double>(output_height) / frame->height});
    width = std::max(1, static_cast<int>(std::lround(frame->width * factor)));
    height = std::max(1, static_cast<int>(std::lround(frame->height * factor)));
    sar = av_mul_q(sar, av_div_q(AVRational{frame->width, frame->height},
                                AVRational{width, height}));
  }
  const int stride = width * 4;
  const int bytes = av_image_get_buffer_size(AV_PIX_FMT_RGBA, width, height, 1);
  if (bytes <= 0 || static_cast<size_t>(bytes) > kMaxVideoBytes) return nullptr;
  const AVColorRange source_range =
      frame->color_range != AVCOL_RANGE_UNSPECIFIED ? frame->color_range :
      stream->codecpar->color_range;
  const AVColorSpace source_space =
      frame->colorspace != AVCOL_SPC_UNSPECIFIED ? frame->colorspace :
      stream->codecpar->color_space;
  auto *output = new (std::nothrow) VideoOutputFrame{};
  if (!output) return nullptr;
  output->buffers = scale->buffers;
  // Borrow the planes synchronously. HDR/DV conversion keeps high precision
  // until the output-sized GPU surface is mapped to the public RGBA buffer.
  AVFrame source = *picture;
  source.color_range = source_range == AVCOL_RANGE_JPEG
                           ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG;
  source.colorspace = source_space == AVCOL_SPC_BT709 ||
                              source_space == AVCOL_SPC_BT2020_NCL
                          ? source_space : AVCOL_SPC_SMPTE170M;
  const int transfer = frame->color_trc != AVCOL_TRC_UNSPECIFIED
                           ? frame->color_trc
                           : stream->codecpar->color_trc;
  bool converted = false;
  bool linear_half = false;
  source.color_trc = static_cast<AVColorTransferCharacteristic>(transfer);
  if (source.color_primaries == AVCOL_PRI_UNSPECIFIED)
    source.color_primaries = stream->codecpar->color_primaries;
  const bool use_rpu = dovi_decision.use_rpu != 0;
#if defined(_WIN32)
  // Ordinary SDR decoder textures can stay on the GPU too. Keep this output
  // encoded RGBA8 even on an HDR desktop; the presenter owns SDR white policy.
  if (gpu_video && source.format == AV_PIX_FMT_D3D11 && !use_rpu &&
      transfer != AVCOL_TRC_SMPTE2084 && transfer != AVCOL_TRC_ARIB_STD_B67) {
    output->gpu_texture = scale->color_pipeline.RenderOwnedTexture(
        &source, width, height, false);
    converted = output->gpu_texture != nullptr;
    if (converted) output->color_path = "gpu-sdr";
  }
#endif
  if (use_rpu || transfer == AVCOL_TRC_SMPTE2084 ||
      transfer == AVCOL_TRC_ARIB_STD_B67) {
    const auto render_color = [&](bool use_dovi) {
      const AVFrame *fel = use_dovi && fel_source ? fel_source : nullptr;
#if defined(_WIN32)
      // The D3D shader reshapes the base planes only. FEL has to take the
      // portable path, which adds the residual after reshape.
      if (!fel && scale->color_pipeline.Render(&source, width, height,
              use_dovi, output->data, stride)) {
        output->color_path = "gpu-readback";
        return true;
      }
#endif
      const bool ok = source.format != AV_PIX_FMT_D3D11 &&
          scale->portable_color_pipeline.Render(&source, width, height,
              use_dovi, output->data, stride, fel);
      if (ok) output->color_path = "portable-sdr";
      return ok;
    };
    const auto accept_base = [&](bool ok) {
      if (!ok) return false;
      if (use_rpu && reconstruction == RILLIGHT_CORE_DOVI_RECON_FEL)
        reconstruction = RILLIGHT_CORE_DOVI_RECON_BASE_FALLBACK;
      else if (use_rpu)
        reconstruction = RILLIGHT_CORE_DOVI_RECON_BASE_FALLBACK;
      return true;
    };
#if defined(_WIN32)
    // The scRGB shader reshapes base planes only. A composed FEL frame is the
    // portable reshape-then-NLQ result, stored as FP16 scRGB for the HDR host.
    // Upload waits until that copy is visible to the other D3D11 device.
    // A failed wait or upload stays a base-layer fallback and is not FEL.
    // Falling through to 8-bit Render would mark the same frame as SDR.
    if (gpu_video && hdr_video && fel_source) {
      const int half_stride = width * 8;
      const int half_bytes = half_stride * height;
      if (half_bytes > 0 && static_cast<size_t>(half_bytes) <= kMaxVideoBytes) {
        uint8_t* half = output->buffers->Acquire(static_cast<size_t>(half_bytes));
        if (half && scale->portable_color_pipeline.RenderLinearHalf(
                        &source, width, height, true,
                        reinterpret_cast<uint16_t*>(half), half_stride, fel_source)) {
          void* texture = scale->color_pipeline.UploadScRgbHalf(
              reinterpret_cast<const uint16_t*>(half), width, height, half_stride);
          if (texture) {
            output->gpu_texture = std::shared_ptr<void>(texture, [](void* pointer) {
              static_cast<ID3D11Texture2D*>(pointer)->Release();
            });
            converted = true;
            output->color_path = "fel-linear-gpu";
          }
        }
        if (half) output->buffers->Recycle(half, static_cast<size_t>(half_bytes));
      }
      if (!converted) {
        reconstruction = RILLIGHT_CORE_DOVI_RECON_BASE_FALLBACK;
        fel_source = nullptr;
      }
    }
    if (gpu_video && !fel_source) {
      const auto render_texture = [&](bool use_dovi) {
        return scale->color_pipeline.RenderOwnedTexture(&source, width, height,
            use_dovi, hdr_video ? 203.0f : 0.0f);
      };
      auto texture = render_texture(use_rpu);
      bool used_base = false;
      if (!texture && use_rpu && base_allowed) {
        texture = render_texture(false);
        used_base = texture != nullptr;
      }
      if (texture) {
        output->gpu_texture = std::move(texture);
        converted = true;
        output->color_path = hdr_video ? "gpu-scrgb" : "gpu-sdr";
        if (used_base) reconstruction = RILLIGHT_CORE_DOVI_RECON_BASE_FALLBACK;
      }
    }
#else
    (void)gpu_video;
    (void)hdr_video;
#endif
    if (!converted && (macos_edr || linear_cpu)) {
      const int half_stride = width * 8;
      const int half_bytes = half_stride * height;
      if (half_bytes > 0 && static_cast<size_t>(half_bytes) <= kMaxVideoBytes) {
        output->data = output->buffers->Acquire(half_bytes);
        if (!output->data) { delete output; return nullptr; }
        const auto render_half = [&](bool use_dovi) {
          const AVFrame *fel = use_dovi && fel_source ? fel_source : nullptr;
          return scale->portable_color_pipeline.RenderLinearHalf(
              &source, width, height, use_dovi,
              reinterpret_cast<uint16_t*>(output->data), half_stride, fel);
        };
        converted = render_half(use_rpu);
        if (!converted && use_rpu && base_allowed)
          converted = accept_base(render_half(false));
        linear_half = converted;
        if (converted) output->color_path = scale->portable_color_pipeline.UsedMetal()
            ? "metal-linear" : "portable-linear";
        if (!converted) {
          output->buffers->Recycle(output->data, half_bytes);
          output->data = nullptr;
        }
      }
    }
    if (!converted) {
      output->data = output->buffers->Acquire(bytes);
      if (!output->data) { delete output; return nullptr; }
      converted = render_color(use_rpu);
    }
    // A compatible base stays valid when residual composition or RPU reshape
    // fails. Profile 5 has no such base and must not be tone-mapped as HDR10.
    if (!converted && use_rpu && base_allowed)
      converted = accept_base(render_color(false));
  }
  if (!converted && profile == 5) {
    if (output->data) output->buffers->Recycle(output->data, output->data ? bytes : 0);
    delete output;
    if (convert_error) *convert_error = RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI;
    return nullptr;
  }
  // swscale cannot read a D3D11 texture. Let the common hardware-download
  // fallback retry CPU planes, preserving metadata and decoder ownership.
  if (!converted && source.format == AV_PIX_FMT_D3D11) {
    if (output->data) output->buffers->Recycle(output->data, bytes);
    delete output;
    return nullptr;
  }
  if (!converted) {
    if (!output->data) output->data = output->buffers->Acquire(bytes);
    if (!output->data) { delete output; return nullptr; }
    if (!scale->context) {
      scale->context = sws_alloc_context();
      if (!scale->context) {
        output->buffers->Recycle(output->data, bytes);
        delete output;
        return nullptr;
      }
      scale->context->threads = software_thread_budget();
      scale->context->flags = SWS_BILINEAR;
      scale->context->backends = SWS_BACKEND_LEGACY;
    }
  AVFrame destination{};
  destination.width = width;
  destination.height = height;
  destination.format = AV_PIX_FMT_RGBA;
  destination.data[0] = output->data;
  destination.linesize[0] = stride;
  destination.color_range = AVCOL_RANGE_JPEG;
  destination.colorspace = AVCOL_SPC_RGB;
  destination.color_primaries = source.color_primaries;
  destination.color_trc = source.color_trc;
  destination.flags = source.flags;
  if (sws_scale_frame(scale->context, &destination, &source) < 0) {
    output->buffers->Recycle(output->data, bytes);
    delete output;
    return nullptr;
  }
  tonemap_rgba(output->data, stride, width, height, transfer);
  output->color_path = "swscale";
  }
  output->struct_size = sizeof(RillightCoreFrame);
  output->type = output->gpu_texture ? RILLIGHT_CORE_VIDEO_D3D11 :
      linear_half ? RILLIGHT_CORE_VIDEO_RGBA16F : RILLIGHT_CORE_VIDEO_RGBA;
  output->session_id = session;
  output->timeline_version = timeline;
  output->pts_us = pts;
  output->width = width;
  output->height = height;
  const bool gpu_half = output->gpu_texture && hdr_video &&
      (use_rpu || transfer == AVCOL_TRC_SMPTE2084 || transfer == AVCOL_TRC_ARIB_STD_B67);
  output->stride = linear_half ? width * 8 : gpu_half ? stride * 2 : stride;
  output->data_size = linear_half ? width * height * 8 : gpu_half ? bytes * 2 : bytes;
  output->sar_num = sar.num;
  output->sar_den = sar.den;
  output->source_color_range = source_range;
  output->source_color_space = source_space;
  output->source_color_primaries =
      frame->color_primaries != AVCOL_PRI_UNSPECIFIED ?
      frame->color_primaries : stream->codecpar->color_primaries;
  output->source_color_transfer =
      frame->color_trc != AVCOL_TRC_UNSPECIFIED ?
      frame->color_trc : stream->codecpar->color_trc;
  const AVFrameSideData *matrix =
      av_frame_get_side_data(frame, AV_FRAME_DATA_DISPLAYMATRIX);
  if (matrix && matrix->size >= sizeof(output->display_matrix)) {
    std::memcpy(output->display_matrix, matrix->data,
                sizeof(output->display_matrix));
    output->has_display_matrix = 1;
  } else {
    const AVPacketSideData *stream_matrix = av_packet_side_data_get(
        stream->codecpar->coded_side_data,
        stream->codecpar->nb_coded_side_data,
        AV_PKT_DATA_DISPLAYMATRIX);
    if (stream_matrix &&
        stream_matrix->size >= sizeof(output->display_matrix)) {
      std::memcpy(output->display_matrix, stream_matrix->data,
                  sizeof(output->display_matrix));
      output->has_display_matrix = 1;
    }
  }
  output->dovi_reconstruction = reconstruction;
  return output;
}

int convert_video_frame(RillightCoreImpl *core, AVFormatContext *format,
                        AVFrame *decoded, int stream_index, uint32_t hardware,
                        VideoScale *scale, std::vector<SubtitleCue> *cues,
                        AssRenderer *ass, uint64_t session, uint64_t timeline,
                        std::mutex *subtitle_mutex) {
  int result = 0;
  const int64_t pts = media_pts_us(
      core, frame_time(decoded, format->streams[stream_index]));
  bool discard = false;
  int output_width;
  int output_height;
  bool gpu_video = false;
  bool hdr_video = false;
  bool macos_edr = false;
  {
    std::lock_guard lock(core->mutex);
    output_width = core->output_width;
    output_height = core->output_height;
    hdr_video = core->hdr_video;
    macos_edr = core->macos_edr;
    // Both SDR and HDR presenters compose the cropped subtitle overlay.
    // Selecting a subtitle must not force every Dolby frame through readback.
    gpu_video = core->gpu_video;
    const int64_t clock = playback_position(core);
    discard = core->timeline != timeline ||
        (pts >= 0 &&
         (((core->state == RILLIGHT_CORE_RECOVERING ||
            core->state == RILLIGHT_CORE_OPENING) &&
           pts + 5000 < core->base_position) ||
          (core->state == RILLIGHT_CORE_PLAYING && core->first_video &&
           pts + 100000 < clock)));
  }
  struct FrameRelease {
    AVFrame* frame = nullptr;
    ~FrameRelease() { av_frame_free(&frame); }
  } enhancement_frame, mapped_frame;
  if (scale->enhancement.enabled)
    enhancement_frame.frame = scale->enhancement.Take(pts);
  if (discard) {
    // Decode reference frames, but skip GPU readback, RGBA conversion and
    // subtitle composition for output that is already late. Doing all that
    // work before the renderer drops it delays subsequent useful pictures.
    return 0;
  }
  const auto conversion_started = Clock::now();
  bool downloaded_for_color = false;
  const AVFrame *picture = decoded;
  bool decoded_with_hardware = false;
  RillightCoreFrame *output = nullptr;
#if defined(__ANDROID__)
  bool android_color = hardware == RILLIGHT_CORE_HW_MEDIACODEC &&
      (decoded->format == AV_PIX_FMT_P010LE || decoded->format == AV_PIX_FMT_NV12 ||
       (decoded->format == AV_PIX_FMT_MEDIACODEC && AndroidDoviSurface::From(decoded))) &&
      av_frame_get_side_data(decoded, AV_FRAME_DATA_DOVI_METADATA);
  if (android_color) {
    rillight_color::Constants scratch{};
    const bool usable = rillight_color::DoviConstants(decoded, &scratch, false);
    const auto *parameters = format->streams[stream_index]->codecpar;
    const auto *configuration = av_packet_side_data_get(
        parameters->coded_side_data, parameters->nb_coded_side_data,
        AV_PKT_DATA_DOVI_CONF);
    const int profile = configuration && configuration->data &&
            configuration->size >= sizeof(AVDOVIDecoderConfigurationRecord)
        ? reinterpret_cast<const AVDOVIDecoderConfigurationRecord *>(
              configuration->data)->dv_profile
        : 0;
    // The P010 shader cannot reshape a residual or a missing Profile 5 RPU.
    // Profile 5 must fail closed; other profiles fall through to CPU reconstruction.
    if (!usable) {
      if (profile == 5) return RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI;
      android_color = false;
    }
  }
  if (android_color || (hardware == RILLIGHT_CORE_HW_MEDIACODEC &&
      decoded->format == AV_PIX_FMT_MEDIACODEC && decoded->data[3])) {
    auto* native = new (std::nothrow) VideoOutputFrame{};
    AVFrame* retained = av_frame_clone(decoded);
    if (!native || !retained) {
      delete native;
      av_frame_free(&retained);
      return AVERROR(ENOMEM);
    }
    native->codec_frame = std::shared_ptr<AVFrame>(retained,
        [](AVFrame* frame) { av_frame_free(&frame); });
    native->struct_size = sizeof(RillightCoreFrame);
    native->type = android_color ? RILLIGHT_CORE_VIDEO_ANDROID_P010 : RILLIGHT_CORE_VIDEO_MEDIACODEC;
    native->session_id = session;
    native->timeline_version = timeline;
    native->pts_us = pts;
    native->width = decoded->width;
    native->height = decoded->height;
    native->sar_num = decoded->sample_aspect_ratio.num > 0 ? decoded->sample_aspect_ratio.num : 1;
    native->sar_den = decoded->sample_aspect_ratio.den > 0 ? decoded->sample_aspect_ratio.den : 1;
    const int64_t cost = video_frame_cost(decoded);
    if (cost <= 0 || cost > std::numeric_limits<int>::max()) {
      delete native;
      return AVERROR_INVALIDDATA;
    }
    native->data_size = static_cast<int>(cost);
    native->source_color_range = decoded->color_range;
    native->source_color_space = decoded->colorspace;
    native->source_color_primaries = decoded->color_primaries;
    native->source_color_transfer = decoded->color_trc;
    if (android_color)
      native->dovi_reconstruction = RILLIGHT_CORE_DOVI_RECON_RPU;
    const auto* matrix = av_packet_side_data_get(
        format->streams[stream_index]->codecpar->coded_side_data,
        format->streams[stream_index]->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    if (matrix && matrix->size >= sizeof(native->display_matrix)) {
      std::memcpy(native->display_matrix, matrix->data, sizeof(native->display_matrix));
      native->has_display_matrix = 1;
    }
    output = native;
    decoded_with_hardware = output != nullptr;
  }
#endif
#if defined(_WIN32)
  const auto* video_stream = format->streams[stream_index];
  const int transfer = decoded->color_trc == AVCOL_TRC_UNSPECIFIED
      ? video_stream->codecpar->color_trc : decoded->color_trc;
  const bool gpu_color = gpu_video || transfer == AVCOL_TRC_SMPTE2084 ||
      transfer == AVCOL_TRC_ARIB_STD_B67 ||
      av_frame_get_side_data(decoded, AV_FRAME_DATA_DOVI_METADATA) != nullptr;
  if (gpu_color && !scale->hardware_color_failed && decoded->format == AV_PIX_FMT_D3D11 &&
      decoded->hw_frames_ctx) {
    int convert_error = 0;
    output = convert_video(decoded, pts, session, timeline,
        format->streams[stream_index], scale, output_width, output_height,
        gpu_video, hdr_video, macos_edr, enhancement_frame.frame, &convert_error);
    // A valid RPU can outlive a GPU interop failure. The same high-precision
    // frame (and its metadata) can still use the portable mapper after download.
    // Both first-frame and queued-frame conversion use this bounded fallback.
    if (!output) scale->hardware_color_failed = true;
    decoded_with_hardware = output != nullptr;
  }
#endif
  // CPU planes alone do not identify the decoder backend. Our locked
  // MediaCodec wrapper carries its actual component name on byte output.
#if defined(__ANDROID__)
  if (hardware == RILLIGHT_CORE_HW_MEDIACODEC && av_dict_get(
      decoded->metadata, "rillight.mediacodec.name", nullptr, 0))
    decoded_with_hardware = true;
#endif
#if defined(__APPLE__)
  if (!output && decoded->format == AV_PIX_FMT_VIDEOTOOLBOX && decoded->hw_frames_ctx) {
    // VideoToolbox can expose the existing CVPixelBuffer planes read-only.
    // Keep the mapping alive through conversion, then unlock/release it before
    // returning; the output owns independent pixels. Unsupported mapping still
    // uses the established transfer path below.
    mapped_frame.frame = av_frame_alloc();
    if (mapped_frame.frame && av_hwframe_map(mapped_frame.frame, decoded,
            AV_HWFRAME_MAP_READ | AV_HWFRAME_MAP_DIRECT) >= 0) {
      picture = mapped_frame.frame;
      decoded_with_hardware = true;
    } else {
      av_frame_free(&mapped_frame.frame);
    }
  }
#endif
  if (!output && picture == decoded && hardware != RILLIGHT_CORE_HW_NONE && decoded->hw_frames_ctx) {
    // Retain the CPU planes between downloads. Allocating/freeing a new
    // 4K staging frame on every transfer adds page faults to the video lane.
    // A different hardware frames context invalidates both size and format.
    if (!scale->download_context ||
        scale->download_context->data != decoded->hw_frames_ctx->data) {
      av_frame_free(&scale->downloaded);
      av_buffer_unref(&scale->download_context);
      scale->download_context = av_buffer_ref(decoded->hw_frames_ctx);
    }
    if (!scale->downloaded) scale->downloaded = av_frame_alloc();
    if (!scale->downloaded || !scale->download_context) {
      return AVERROR(ENOMEM);
    }
    result = av_hwframe_transfer_data(scale->downloaded, decoded, 0);
    // copy_props appends side data; clear the preceding frame's metadata
    // without releasing the reusable pixel allocation.
    av_frame_side_data_free(&scale->downloaded->side_data,
                            &scale->downloaded->nb_side_data);
    av_dict_free(&scale->downloaded->metadata);
    if (result >= 0)
      result = av_frame_copy_props(scale->downloaded, decoded);
    if (result < 0) {
      return result;
    } else {
      picture = scale->downloaded;
      downloaded_for_color = true;
      decoded_with_hardware = true;
    }
  }
  int convert_error = 0;
  if (!output && picture)
    output = convert_video(picture, pts, session, timeline,
                           format->streams[stream_index], scale, output_width,
                           output_height, gpu_video, hdr_video,
                           macos_edr, enhancement_frame.frame, &convert_error);
  if (!output) {
    return convert_error < 0 ? convert_error : AVERROR(EINVAL);
  }
  {
    std::lock_guard lock(core->mutex);
    if (core->timeline == timeline && !core->stop) {
      const auto* color_path = static_cast<VideoOutputFrame*>(output)->color_path;
      const std::string mapped_path = mapped_frame.frame
          ? std::string("mapped+") + color_path : std::string{};
      if (output->type == RILLIGHT_CORE_VIDEO_MEDIACODEC)
        core->video_processing.NativeSurface();
      else if (output->type != RILLIGHT_CORE_VIDEO_ANDROID_P010)
        core->video_processing.Record(
          mapped_frame.frame ? mapped_path.c_str() : color_path, downloaded_for_color,
          std::chrono::duration_cast<std::chrono::microseconds>(
              Clock::now() - conversion_started).count());
      if (decoded_with_hardware) {
        for (auto &track : core->tracks) {
          if (track.stream_index == stream_index) track.actual_hardware = hardware;
        }
      }
    }
  }
  (void)cues; (void)ass; (void)subtitle_mutex;
  return enqueue(core, output, stream_index, timeline);
}
}  // namespace rillight::core
