#include "core_decoder.h"

namespace rillight::core {
AVHWDeviceType hardware_device_type(RillightCoreHardware hardware) {
  switch (hardware) {
    case RILLIGHT_CORE_HW_D3D11: return AV_HWDEVICE_TYPE_D3D11VA;
    case RILLIGHT_CORE_HW_VIDEOTOOLBOX: return AV_HWDEVICE_TYPE_VIDEOTOOLBOX;
    case RILLIGHT_CORE_HW_VAAPI: return AV_HWDEVICE_TYPE_VAAPI;
    case RILLIGHT_CORE_HW_MEDIACODEC: return AV_HWDEVICE_TYPE_MEDIACODEC;
    default: return AV_HWDEVICE_TYPE_NONE;
  }
}

const char *mediacodec_decoder_name(AVCodecID codec) {
  switch (codec) {
    case AV_CODEC_ID_H264: return "h264_mediacodec";
    case AV_CODEC_ID_HEVC: return "hevc_mediacodec";
    case AV_CODEC_ID_AV1: return "av1_mediacodec";
    case AV_CODEC_ID_VP8: return "vp8_mediacodec";
    case AV_CODEC_ID_VP9: return "vp9_mediacodec";
    case AV_CODEC_ID_MPEG2VIDEO: return "mpeg2_mediacodec";
    case AV_CODEC_ID_MPEG4: return "mpeg4_mediacodec";
    default: return nullptr;
  }
}

AVPixelFormat choose_hardware_format(AVCodecContext *context,
                                     const AVPixelFormat *formats) {
  const auto *selection =
      static_cast<HardwareFormatSelection *>(context->opaque);
  for (const AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE;
       ++format) {
    if (*format == selection->preferred) return *format;
  }
  // A device may initialize successfully yet reject a particular stream
  // profile at the first frame (for example AV1 on software Mesa VAAPI).
  // FFmpeg calls get_format again with the remaining software formats.
  if (selection->allow_software_fallback) {
    for (const AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE;
         ++format) {
      const AVPixFmtDescriptor *description = av_pix_fmt_desc_get(*format);
      if (description && !(description->flags & AV_PIX_FMT_FLAG_HWACCEL))
        return *format;
    }
  }
  return AV_PIX_FMT_NONE;
}

AVPixelFormat choose_software_format(AVCodecContext *,
                                     const AVPixelFormat *formats) {
  for (const AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE;
       ++format) {
    const AVPixFmtDescriptor *description = av_pix_fmt_desc_get(*format);
    if (description && !(description->flags & AV_PIX_FMT_FLAG_HWACCEL))
      return *format;
  }
  return AV_PIX_FMT_NONE;
}

// FFmpeg decodes with a single thread unless configured otherwise. Software
// paths (and the bitstream half of hwaccel paths) must budget real threads the
// way mpv does, or high-bitrate HEVC/Dolby decode stutters on capable CPUs.
int software_thread_budget() {
  const int cores = av_cpu_count();
  return cores > 0 ? std::min(16, cores) : 1;
}

std::string truncate_for_diagnostics(const std::string &value, size_t limit) {
  if (value.size() <= limit) return value;
  return value.substr(0, limit) + "...";
}

#if defined(_WIN32)
// DXVA decoder profile GUIDs. Declared locally so the core does not depend on
// dxguid.lib or on SDK header version differences.
constexpr GUID kGuidH264VldNoFgt = {0x1b81be68, 0xa0c7, 0x11d3,
    {0xb9, 0x84, 0x00, 0xc0, 0x4f, 0x2e, 0x73, 0xc5}};
constexpr GUID kGuidHevcVldMain = {0x5b11d51b, 0x2f4c, 0x4452,
    {0xbc, 0xc3, 0x09, 0xf2, 0xa1, 0x16, 0x0c, 0xc0}};
constexpr GUID kGuidHevcVldMain10 = {0x107af0e0, 0xef1a, 0x4d19,
    {0xab, 0xa8, 0x67, 0xa1, 0x63, 0x07, 0x3d, 0x13}};
constexpr GUID kGuidVp9VldProfile0 = {0x463707f8, 0xa1d0, 0x4585,
    {0x87, 0x6d, 0x83, 0xaa, 0x6d, 0x60, 0xb8, 0x9e}};
constexpr GUID kGuidAv1VldProfile0 = {0xb8be4ccb, 0xcf53, 0x46ba,
    {0x8d, 0x59, 0xd6, 0xb8, 0xa6, 0xda, 0x5d, 0x2a}};

std::string d3d11_adapter_name(IDXGIAdapter *adapter) {
  if (!adapter) return "default";
  DXGI_ADAPTER_DESC description{};
  if (FAILED(adapter->GetDesc(&description))) return "unknown";
  char name[80]{};
  WideCharToMultiByte(CP_UTF8, 0, description.Description, -1, name,
                      sizeof(name) - 1, nullptr, nullptr);
  return name[0] ? name : "unknown";
}

// Ask the driver whether this device can actually decode the stream's DXVA
// profile. Returns an empty string when supported, otherwise the reason.
// Unknown codec/profile combinations return empty: the decoder open itself
// then decides, exactly as before this probe existed.
std::string d3d11_decode_gap(ID3D11Device *device, AVCodecID codec,
                             int profile, int pixel_format) {
  const GUID *guid = nullptr;
  DXGI_FORMAT output = DXGI_FORMAT_NV12;
  const bool ten_bit = pixel_format == AV_PIX_FMT_YUV420P10 ||
                       pixel_format == AV_PIX_FMT_P010;
  switch (codec) {
    case AV_CODEC_ID_H264:
      guid = &kGuidH264VldNoFgt;
      break;
    case AV_CODEC_ID_HEVC:
      guid = profile == AV_PROFILE_HEVC_MAIN_10 || ten_bit
                 ? &kGuidHevcVldMain10
                 : &kGuidHevcVldMain;
      if (profile == AV_PROFILE_HEVC_MAIN_10 || ten_bit)
        output = DXGI_FORMAT_P010;
      break;
    case AV_CODEC_ID_VP9:
      guid = &kGuidVp9VldProfile0;
      break;
    case AV_CODEC_ID_AV1:
      guid = &kGuidAv1VldProfile0;
      break;
    default:
      return {};
  }
  ID3D11VideoDevice *video = nullptr;
  if (FAILED(device->QueryInterface(__uuidof(ID3D11VideoDevice),
                                    reinterpret_cast<void **>(&video))) ||
      !video) {
    if (video) video->Release();
    return "no ID3D11VideoDevice";
  }
  BOOL listed = FALSE;
  UINT count = video->GetVideoDecoderProfileCount();
  for (UINT index = 0; index < count && !listed; ++index) {
    GUID each{};
    if (SUCCEEDED(video->GetVideoDecoderProfile(index, &each)) &&
        IsEqualGUID(each, *guid))
      listed = TRUE;
  }
  std::string gap;
  if (!listed) {
    gap = "dxva profile not enumerated";
  } else {
    BOOL format_supported = FALSE;
    if (FAILED(video->CheckVideoDecoderFormat(guid, output,
                                              &format_supported)) ||
        !format_supported)
      gap = output == DXGI_FORMAT_P010 ? "P010 output unsupported"
                                       : "NV12 output unsupported";
  }
  video->Release();
  return gap;
}

// Create the decode device on the presenter's adapter so decode, composition
// and presentation share one adapter and legacy shared textures stay openable.
// Returns AVERROR(0) on success; a negative FFmpeg error otherwise, with the
// creation HRESULT appended to diagnostics.
int create_attached_d3d11_hwdevice(AVBufferRef **out, IDXGIAdapter *adapter,
                                   AVCodecID codec, int profile,
                                   int pixel_format, std::string *diagnostics) {
  *out = nullptr;
  AVBufferRef *reference = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA);
  if (!reference) return AVERROR(ENOMEM);
  auto *device_context =
      reinterpret_cast<AVHWDeviceContext *>(reference->data);
  auto *d3d11 = static_cast<AVD3D11VADeviceContext *>(device_context->hwctx);
  ID3D11Device *device = nullptr;
  ID3D11DeviceContext *context = nullptr;
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1,
                                      D3D_FEATURE_LEVEL_11_0};
  const HRESULT created = D3D11CreateDevice(
      adapter, adapter ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE,
      nullptr,
      D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
      levels, ARRAYSIZE(levels), D3D11_SDK_VERSION, &device, nullptr,
      &context);
  if (FAILED(created) || !device || !context) {
    if (device) device->Release();
    if (context) context->Release();
    av_buffer_unref(&reference);
    char message[96];
    std::snprintf(message, sizeof(message),
                  "D3D11CreateDevice hr=0x%08lx on '%s'",
                  static_cast<unsigned long>(created),
                  d3d11_adapter_name(adapter).c_str());
    if (diagnostics) *diagnostics = message;
    return AVERROR_EXTERNAL;
  }
  const std::string gap = d3d11_decode_gap(device, codec, profile,
                                           pixel_format);
  if (!gap.empty()) {
    device->Release();
    context->Release();
    av_buffer_unref(&reference);
    if (diagnostics)
      *diagnostics = "adapter '" + d3d11_adapter_name(adapter) + "': " + gap;
    return AVERROR(ENOSYS);
  }
  d3d11->device = device;        // References transfer to the hwdevice.
  d3d11->device_context = context;
  // Leave the callbacks unset so FFmpeg installs its recursive device lock.
  const int initialized = av_hwdevice_ctx_init(reference);
  if (initialized < 0) {
    av_buffer_unref(&reference);
    if (diagnostics)
      *diagnostics = "av_hwdevice_ctx_init " +
                     std::to_string(initialized) + " on '" +
                     d3d11_adapter_name(adapter) + "'";
    return initialized;
  }
  if (diagnostics)
    *diagnostics = "adapter '" + d3d11_adapter_name(adapter) + "'";
  *out = reference;
  return 0;
}
#endif

Decoder make_decoder(AVFormatContext *format, int index,
                     RillightCoreHardware preference,
                     bool allow_software_fallback,
                     const std::shared_ptr<void>& android_window,
                     uint32_t android_dovi_profiles,
                     int64_t discard_before_us,
                     bool dovi_8bit,
                     const std::shared_ptr<AndroidTunnelFactory>& tunnel_factory,
                     uint32_t tunnel_profiles,
                     void *windows_dxgi_adapter) {
#if !defined(_WIN32)
  (void)windows_dxgi_adapter;
#endif
  std::shared_ptr<void> decoder_window = android_window;
  Decoder result;
  if (index < 0 || index >= static_cast<int>(format->nb_streams)) return result;
  const auto *parameters = format->streams[index]->codecpar;
  if (tunnel_factory && android_window && preference == RILLIGHT_CORE_HW_MEDIACODEC &&
      parameters->codec_id == AV_CODEC_ID_HEVC) {
    const auto* side = av_packet_side_data_get(parameters->coded_side_data,
        parameters->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
    const auto* record = side && side->size >= sizeof(AVDOVIDecoderConfigurationRecord)
        ? reinterpret_cast<const AVDOVIDecoderConfigurationRecord*>(side->data) : nullptr;
    if (record && android_dovi_profile_supported(record->dv_profile, tunnel_profiles) &&
        !record->el_present_flag) {
      auto tunnel = std::make_shared<TunnelDecoder>();
      const auto* bsf = av_bsf_get_by_name("hevc_mp4toannexb");
      if (bsf && av_bsf_alloc(bsf, &tunnel->filter) >= 0 &&
          avcodec_parameters_copy(tunnel->filter->par_in, parameters) >= 0) {
        tunnel->filter->time_base_in = format->streams[index]->time_base;
        if (av_bsf_init(tunnel->filter) >= 0) {
          tunnel->factory = tunnel_factory; tunnel->window = android_window;
          tunnel->width = parameters->width; tunnel->height = parameters->height;
          tunnel->profile = 1 << record->dv_profile;
          tunnel->level = record->dv_level >= 1 && record->dv_level <= 13
              ? 1 << (record->dv_level - 1) : 0;
          tunnel->config.resize(24);
          tunnel->config[0] = record->dv_version_major;
          tunnel->config[1] = record->dv_version_minor;
          tunnel->config[2] = (record->dv_profile << 1) | (record->dv_level >> 5);
          tunnel->config[3] = (record->dv_level << 3) |
              (record->rpu_present_flag << 2) | record->bl_present_flag;
          tunnel->config[4] = record->dv_bl_signal_compatibility_id << 4;
          tunnel->time_base = tunnel->filter->time_base_out;
          tunnel->discard_before = std::max<int64_t>(0, discard_before_us);
          const auto rate = av_guess_frame_rate(format, format->streams[index], nullptr);
          if (rate.num > 0 && rate.den > 0)
            tunnel->rate = std::clamp(static_cast<int>(std::ceil(av_q2d(rate))), 1, 240);
          const auto* extra = tunnel->filter->par_out;
          if (extra->extradata_size > 0 && extra->extradata_size < 1024 * 1024)
            tunnel->csd.assign(extra->extradata, extra->extradata + extra->extradata_size);
          result.context = avcodec_alloc_context3(nullptr);
          if (result.context && avcodec_parameters_to_context(result.context, parameters) >= 0) {
            result.context->pkt_timebase = format->streams[index]->time_base;
            result.stream = index; result.hardware = RILLIGHT_CORE_HW_MEDIACODEC;
            result.tunnel = std::move(tunnel);
            result.android_native_dolby = true;
            result.diagnostics = "hardware mediacodec tunnel";
            return result;
          }
          avcodec_free_context(&result.context);
        }
      }
    }
  }
  bool native_dovi = false;
  bool export_dovi = false;
  if (preference == RILLIGHT_CORE_HW_MEDIACODEC &&
      parameters->codec_id == AV_CODEC_ID_HEVC) {
    const auto* side = av_packet_side_data_get(parameters->coded_side_data,
        parameters->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
    const bool declared_dovi = parameters->codec_tag == MKTAG('d','v','h','1') ||
        parameters->codec_tag == MKTAG('d','v','h','e');
    const AVCodec* platform = avcodec_find_decoder_by_name("hevc_mediacodec");
    const AVClass* options = platform ? platform->priv_class : nullptr;
    const bool dolby_surface = android_dovi_profiles && decoder_window && options &&
        av_opt_find(&options, "codec_mime", nullptr, 0, AV_OPT_SEARCH_FAKE_OBJ);
    const bool dovi_buffers = options && av_opt_find(
        &options, "export_dovi", nullptr, 0, AV_OPT_SEARCH_FAKE_OBJ);
    if (declared_dovi && (!side || side->size < sizeof(AVDOVIDecoderConfigurationRecord))) {
      // Without the recovered profile, neither a Dolby MIME nor ordinary
      // HEVC output establishes the correct color interpretation.
      if (!allow_software_fallback) {
        result.error = RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI;
        return result;
      }
      preference = RILLIGHT_CORE_HW_NONE;
    } else if (side && side->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
      const auto* record = reinterpret_cast<const AVDOVIDecoderConfigurationRecord*>(side->data);
      const bool supports_profile = android_dovi_profile_supported(
          record->dv_profile, android_dovi_profiles);
      // Profile 5 has no ordinary HDR10 base. Prefer a supported native Dolby
      // Surface; otherwise retain HEVC decoding with timestamp-matched RPU
      // and high precision P010 buffers for our color pipeline.
      if (record->dv_profile == 5) {
        if (dolby_surface && supports_profile) native_dovi = true;
        else if (dovi_buffers) export_dovi = true;
        else if (!allow_software_fallback) {
          result.error = RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI;
          return result;
        }
        if (!native_dovi && !export_dovi) preference = RILLIGHT_CORE_HW_NONE;
      } else if (dolby_surface && supports_profile) {
        native_dovi = true;
      }
    }
  }
#if defined(__ANDROID__)
  if (export_dovi) {
    const auto time_base = format->streams[index]->time_base;
    if (AndroidColorPipeline::SupportsPrivateYuv())
      result.android_dovi_surface = AndroidDoviSurface::Create(
          parameters->width, parameters->height, time_base.num, time_base.den);
    decoder_window = result.android_dovi_surface
        ? std::shared_ptr<void>(result.android_dovi_surface, result.android_dovi_surface->Window())
        : std::shared_ptr<void>{};
  }
#endif
  // FFmpeg's native AV1 decoder handles hardware surfaces only. A software
  // request must select the separately bundled dav1d decoder explicitly.
  const AVCodec *codec = preference == RILLIGHT_CORE_HW_NONE &&
                                 parameters->codec_id == AV_CODEC_ID_AV1
      ? avcodec_find_decoder_by_name("libdav1d")
      : avcodec_find_decoder(parameters->codec_id);
  if (preference == RILLIGHT_CORE_HW_MEDIACODEC &&
      parameters->codec_type == AVMEDIA_TYPE_VIDEO) {
    const char *name = mediacodec_decoder_name(parameters->codec_id);
    const AVCodec *platform = name ? avcodec_find_decoder_by_name(name) : nullptr;
    if (platform) codec = platform;
  }
  if (!codec) { result.error = AVERROR_DECODER_NOT_FOUND; return result; }
  AVCodecContext *context = avcodec_alloc_context3(codec);
  if (!context) { result.error = AVERROR(ENOMEM); return result; }
  if (avcodec_parameters_to_context(context, parameters) < 0) {
    avcodec_free_context(&context);
    result.error = AVERROR(EINVAL);
    return result;
  }
  // Audio decoders also need this to preserve timestamps when removing
  // priming samples. Without it the audio clock can remain unavailable.
  context->pkt_timebase = format->streams[index]->time_base;
  if (parameters->codec_type == AVMEDIA_TYPE_VIDEO) {
    // Auto threads match mpv: one decode thread cannot keep up with modern
    // HEVC/Dolby bitrates on CPUs that software-decode fine elsewhere. The
    // explicit budget (rather than 0/auto) is reported in diagnostics.
    context->thread_count = software_thread_budget();
    context->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    // Frame-only decoders retain the first picture until enough subsequent
    // video packets arrive. Sparse A/V interleaving can exhaust the bounded
    // pre-picture audio queue first. Keep those codecs low latency; HEVC/H264
    // and decoders with their own threading retain the full thread budget.
    if ((codec->capabilities & AV_CODEC_CAP_FRAME_THREADS) &&
        !(codec->capabilities & AV_CODEC_CAP_SLICE_THREADS))
      context->thread_count = 1;
  }
  if (preference == RILLIGHT_CORE_HW_NONE &&
      parameters->codec_type == AVMEDIA_TYPE_VIDEO)
    context->get_format = choose_software_format;
  std::string hw_note;
  if (preference != RILLIGHT_CORE_HW_NONE &&
      parameters->codec_type == AVMEDIA_TYPE_VIDEO) {
    const AVHWDeviceType device_type = hardware_device_type(preference);
    const AVCodecHWConfig *selected = nullptr;
    for (int config_index = 0;; ++config_index) {
      const AVCodecHWConfig *config = avcodec_get_hw_config(codec, config_index);
      if (!config) break;
      if (config->device_type == device_type &&
          (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) {
        selected = config;
        break;
      }
    }
    int device_error = AVERROR(ENOSYS);
    if (selected) {
      AVBufferRef *device = nullptr;
#if defined(__ANDROID__)
      if (preference == RILLIGHT_CORE_HW_MEDIACODEC && decoder_window) {
        device = av_hwdevice_ctx_alloc(device_type);
        if (device) {
          auto* device_context = reinterpret_cast<AVHWDeviceContext*>(device->data);
          auto* mc = static_cast<AVMediaCodecDeviceContext*>(device_context->hwctx);
          mc->native_window = decoder_window.get();
          device_context->user_opaque = new std::shared_ptr<void>(decoder_window);
          device_context->free = [](AVHWDeviceContext* context) {
            delete static_cast<std::shared_ptr<void>*>(context->user_opaque);
          };
          device_error = av_hwdevice_ctx_init(device);
          if (device_error < 0) av_buffer_unref(&device);
        } else device_error = AVERROR(ENOMEM);
      } else
#endif
      {
#if defined(_WIN32)
        if (device_type == AV_HWDEVICE_TYPE_D3D11VA && windows_dxgi_adapter) {
          std::string attached_note;
          device_error = create_attached_d3d11_hwdevice(
              &device, static_cast<IDXGIAdapter *>(windows_dxgi_adapter),
              parameters->codec_id, parameters->profile, parameters->format,
              &attached_note);
          if (device_error < 0) {
            hw_note = "attached d3d11 refused: " + attached_note;
            if (device) av_buffer_unref(&device);
            device = nullptr;
          } else {
            hw_note = attached_note;
          }
        }
#endif
        if (!device) {
          // FFmpeg's own default-adapter creation, including its retry after
          // the attached adapter could not provide decode.
          device_error = av_hwdevice_ctx_create(&device, device_type, nullptr,
                                                nullptr, 0);
#if defined(_WIN32)
          if (device_type == AV_HWDEVICE_TYPE_D3D11VA && device_error >= 0) {
            if (hw_note.empty()) hw_note = "default device";
            else hw_note += "; default device";
          }
#endif
        }
      }
      if (device_error >= 0) {
        context->hw_device_ctx = device;
        result.hw_format = std::make_shared<HardwareFormatSelection>(
            HardwareFormatSelection{selected->pix_fmt,
                                    allow_software_fallback});
        context->opaque = result.hw_format.get();
        context->get_format = choose_hardware_format;
        result.hardware = preference;
        if (!hw_note.empty()) hw_note = "d3d11 " + hw_note;
      }
    }
    if (device_error < 0) {
      avcodec_free_context(&context);
      if (allow_software_fallback) {
        Decoder fallback = make_decoder(format, index, RILLIGHT_CORE_HW_NONE,
                                        true, {}, 0, -1, false, {}, 0);
        if (fallback.context && !hw_note.empty())
          fallback.diagnostics = "hardware refused (" + hw_note + "); " +
                                 fallback.diagnostics;
        return fallback;
      }
      result.error = device_error;
      result.diagnostics = hw_note;
      return result;
    }
  }
  if (preference == RILLIGHT_CORE_HW_MEDIACODEC) {
    // Stay in native buffers even on hosts which installed a Java VM.
    av_opt_set_int(context->priv_data, "ndk_codec", 1, 0);
    av_opt_set_int(context->priv_data, "delay_flush", 1, 0);
    // MediaCodec uses operating-rate to budget decoder resources. In
    // particular, a 60 fps stream must not inherit a device's default rate.
    const AVRational frame_rate = av_guess_frame_rate(
        format, format->streams[index], nullptr);
    if (frame_rate.num > 0 && frame_rate.den > 0) {
      context->framerate = frame_rate;
      av_opt_set_int(context->priv_data, "operating_rate",
          std::clamp<int64_t>((static_cast<int64_t>(frame_rate.num) +
              frame_rate.den - 1) / frame_rate.den, 1, 240), 0);
    }
    if (export_dovi) {
      const int configured = av_opt_set_int(context->priv_data, "export_dovi", 1, 0);
      if (configured < 0) {
        avcodec_free_context(&context);
        result.error = configured;
        return result;
      }
      if (result.android_dovi_surface &&
          av_opt_set_int(context->priv_data, "dovi_surface", 1, 0) < 0) {
        avcodec_free_context(&context);
        if (allow_software_fallback) return make_decoder(format, index);
        result.error = AVERROR(ENOSYS);
        return result;
      }
      if (dovi_8bit) {
        const int configured_depth = av_opt_set_int(context->priv_data, "dovi_8bit", 1, 0);
        if (configured_depth < 0) {
          avcodec_free_context(&context);
          result.error = configured_depth;
          return result;
        }
      }
      if (discard_before_us >= 0)
        av_opt_set_int(context->priv_data, "discard_before", discard_before_us, 0);
    }
    if (native_dovi) {
      const int configured = av_opt_set(context->priv_data, "codec_mime", "video/dolby-vision", 0);
      if (configured < 0) {
        avcodec_free_context(&context);
        result.error = configured;
        return result;
      }
      const auto* side = av_packet_side_data_get(parameters->coded_side_data,
          parameters->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
      if (side && side->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
        const int profile = reinterpret_cast<const AVDOVIDecoderConfigurationRecord*>(side->data)->dv_profile;
        if (profile >= 0 && profile <= 9)
          av_opt_set_int(context->priv_data, "dolby_profile", 1 << profile, 0);
      }
    }
  }
  const int open_result = avcodec_open2(context, codec, nullptr);
  if (open_result < 0) {
    avcodec_free_context(&context);
    // Lack of P010 byte output is not lack of HEVC hardware decoding. Keep
    // timestamp-matched RPU conversion and retry NV12 before software decode.
    if (export_dovi && !result.android_dovi_surface && !dovi_8bit) {
      return make_decoder(format, index, preference, allow_software_fallback,
                          android_window, android_dovi_profiles, discard_before_us, true,
                          {}, 0);
    }
    if (preference != RILLIGHT_CORE_HW_NONE && allow_software_fallback) {
      Decoder fallback = make_decoder(format, index, RILLIGHT_CORE_HW_NONE,
                                      true, {}, 0, -1, false, {}, 0);
      if (fallback.context)
        fallback.diagnostics = "decoder open " + std::to_string(open_result) +
                               (hw_note.empty() ? "" : " (" + hw_note + ")") +
                               "; " + fallback.diagnostics;
      return fallback;
    }
    result.error = open_result;
    result.diagnostics = hw_note;
    return result;
  }
  result.context = context;
  result.stream = index;
  if (parameters->codec_type == AVMEDIA_TYPE_VIDEO) {
    result.diagnostics =
        (result.hardware != RILLIGHT_CORE_HW_NONE
             ? (hw_note.empty() ?
                 (result.hardware == RILLIGHT_CORE_HW_MEDIACODEC ? "mediacodec" :
                  result.hardware == RILLIGHT_CORE_HW_VIDEOTOOLBOX ? "videotoolbox" : "hardware") : hw_note)
             : "software") +
        " ffmpeg_threads=" + std::to_string(context->thread_count);
    result.hardware_diagnostics = result.diagnostics;
  }
  result.android_color_buffers = export_dovi;
  if (native_dovi) {
    uint8_t *mime = nullptr;
    if (av_opt_get(context->priv_data, "codec_mime", 0, &mime) >= 0 && mime &&
        std::strcmp(reinterpret_cast<const char *>(mime), "video/dolby-vision") == 0)
      result.android_native_dolby = true;
    av_freep(&mime);
  }
  return result;
}

bool EnhancementDecoder::OpenDual(AVFormatContext* format, int index) {
  Decoder opened = make_decoder(format, index, RILLIGHT_CORE_HW_NONE);
  if (!opened.context || !format || index < 0) {
    avcodec_free_context(&opened.context);
    return false;
  }
  std::lock_guard lock(mutex);
  avcodec_free_context(&context);
  context = opened.context;
  opened.context = nullptr;
  time_base = format->streams[index]->time_base;
  dual = true;
  enabled = true;
  flushed = false;
  return true;
}

bool EnhancementDecoder::EnsureOpen() {
  if (context) return true;
  if (dual) return false;
  const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
  if (!codec) return false;
  AVCodecContext* created = avcodec_alloc_context3(codec);
  if (!created) return false;
  created->pkt_timebase = time_base;
  if (avcodec_open2(created, codec, nullptr) < 0) {
    avcodec_free_context(&created);
    return false;
  }
  context = created;
  return true;
}

bool EnhancementDecoder::ReceiveOne() {
  if (!context) return false;
  AVFrame* decoded = av_frame_alloc();
  if (!decoded) return false;
  const int result = avcodec_receive_frame(context, decoded);
  if (result < 0) {
    av_frame_free(&decoded);
    return false;
  }
  if (frames.size() >= 8) {
    av_frame_free(&frames.front());
    frames.pop_front();
  }
  frames.push_back(decoded);
  return true;
}

void EnhancementDecoder::Feed(AVPacket* packet) {
  std::lock_guard lock(mutex);
  if (!enabled) {
    av_packet_free(&packet);
    return;
  }
  if (!packet) {
    if (context && !flushed) {
      avcodec_send_packet(context, nullptr);
      flushed = true;
      ReceiveAll();
    }
    return;
  }
  if (!EnsureOpen()) {
    av_packet_free(&packet);
    return;
  }
  flushed = false;
  for (;;) {
    const int result = avcodec_send_packet(context, packet);
    if (result == AVERROR(EAGAIN)) {
      if (!ReceiveOne()) {
        av_packet_free(&packet);
        return;
      }
      continue;
    }
    av_packet_free(&packet);
    if (result >= 0) ReceiveAll();
    return;
  }
}

AVFrame* EnhancementDecoder::Take(int64_t pts_us) {
  std::lock_guard lock(mutex);
  if (!enabled || frames.empty()) return nullptr;
  auto release_until = [&](size_t index) {
    AVFrame* found = frames[index];
    for (size_t i = 0; i < index; ++i) av_frame_free(&frames[i]);
    frames.erase(frames.begin(), frames.begin() + static_cast<std::ptrdiff_t>(index) + 1);
    return found;
  };
  auto stamp_us = [&](const AVFrame* frame) {
    int64_t stamp = frame->best_effort_timestamp;
    if (stamp == AV_NOPTS_VALUE) stamp = frame->pts;
    if (stamp == AV_NOPTS_VALUE || time_base.num <= 0 || time_base.den <= 0)
      return static_cast<int64_t>(AV_NOPTS_VALUE);
    return av_rescale_q(stamp, time_base, AVRational{1, 1000000});
  };
  if (pts_us >= 0) {
    size_t best = frames.size();
    int64_t best_delta = 0;
    for (size_t i = 0; i < frames.size(); ++i) {
      const int64_t stamp = stamp_us(frames[i]);
      if (stamp == AV_NOPTS_VALUE) continue;
      const int64_t delta = stamp > pts_us ? stamp - pts_us : pts_us - stamp;
      if (delta <= 2000 && (best == frames.size() || delta < best_delta)) {
        best = i;
        best_delta = delta;
      }
    }
    if (best < frames.size()) return release_until(best);
    while (!frames.empty()) {
      const int64_t stamp = stamp_us(frames.front());
      if (stamp != AV_NOPTS_VALUE && stamp + 2000 < pts_us) {
        av_frame_free(&frames.front());
        frames.pop_front();
        continue;
      }
      break;
    }
    if (!frames.empty() && stamp_us(frames.front()) == AV_NOPTS_VALUE)
      return release_until(0);
    return nullptr;
  }
  return release_until(0);
}

int find_fel_stream(AVFormatContext* format, int base) {
  if (!format || base < 0 || base >= static_cast<int>(format->nb_streams)) return -1;
  const auto* parameters = format->streams[base]->codecpar;
  const auto* side = av_packet_side_data_get(parameters->coded_side_data,
      parameters->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
  if (!side || !side->data || side->size < sizeof(AVDOVIDecoderConfigurationRecord)) return -1;
  const auto* record = reinterpret_cast<const AVDOVIDecoderConfigurationRecord*>(side->data);
  if (record->dv_profile != 7 || !record->el_present_flag) return -1;
  int candidate = -1;
  for (unsigned index = 0; index < format->nb_streams; ++index) {
    if (static_cast<int>(index) == base) continue;
    const auto* stream = format->streams[index];
    const auto* codec = stream->codecpar;
    if (codec->codec_type != AVMEDIA_TYPE_VIDEO || codec->codec_id != AV_CODEC_ID_HEVC)
      continue;
    if (stream->disposition & AV_DISPOSITION_ATTACHED_PIC) continue;
    if (codec->width <= 0 || codec->height <= 0 ||
        codec->width > parameters->width || codec->height > parameters->height)
      continue;
    if (candidate >= 0) return -1;
    candidate = static_cast<int>(index);
  }
  return candidate;
}

int restore_dovi_configuration(AVFormatContext* format, int index,
                               PendingPackets* pending) {
  if (index < 0) return 0;
  auto* parameters = format->streams[index]->codecpar;
  const auto* existing = av_packet_side_data_get(parameters->coded_side_data,
      parameters->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
  if (parameters->codec_id != AV_CODEC_ID_HEVC || existing ||
      (parameters->codec_tag != MKTAG('d','v','h','1') &&
       parameters->codec_tag != MKTAG('d','v','h','e'))) return 0;
  // A remux may lose dvcC/dvvC. Decode one bounded prefix with FFmpeg to read
  // the actual RPU header, preserving every demuxed packet for normal playback.
  Decoder probe = make_decoder(format, index);
  if (!probe.context) return probe.error;
  AVPacket* packet = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  int profile = 0, result = 0;
  size_t bytes = 0;
  for (int i = 0; packet && frame && i < 2048 && bytes < 16u * 1024u * 1024u; ++i) {
    result = av_read_frame(format, packet);
    if (result < 0) break;
    auto* saved = av_packet_clone(packet);
    if (!saved) { result = AVERROR(ENOMEM); break; }
    pending->values.push_back(saved);
    bytes += static_cast<size_t>(std::max(packet->size, 0));
    if (packet->stream_index == index) {
      result = avcodec_send_packet(probe.context, packet);
      if (result >= 0) {
        while ((result = avcodec_receive_frame(probe.context, frame)) >= 0) {
          profile = dovi_profile_from_frame(frame);
          av_frame_unref(frame);
          if (profile) break;
        }
      }
    }
    av_packet_unref(packet);
    // A cut/remux can start before the first complete VPS/SPS/PPS. Continue
    // within the byte bound until a decodable keyframe supplies the real RPU.
    if (profile || (result < 0 && result != AVERROR(EAGAIN) &&
                    result != AVERROR_INVALIDDATA)) break;
  }
  av_frame_free(&frame);
  av_packet_free(&packet);
  avcodec_free_context(&probe.context);
  if (!profile) return result == AVERROR(ENOMEM) ? result : RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI;
  auto* side = av_packet_side_data_new(&parameters->coded_side_data,
      &parameters->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF,
      sizeof(AVDOVIDecoderConfigurationRecord), 0);
  if (!side) return AVERROR(ENOMEM);
  auto* record = reinterpret_cast<AVDOVIDecoderConfigurationRecord*>(side->data);
  *record = {};
  record->dv_version_major = 1;
  record->dv_profile = static_cast<uint8_t>(profile);
  record->rpu_present_flag = 1;
  record->bl_present_flag = 1;
  record->el_present_flag = profile == 4 || profile == 7;
  record->dv_bl_signal_compatibility_id = profile == 8 ?
      (parameters->color_trc == AVCOL_TRC_ARIB_STD_B67 ? 4 :
       parameters->color_trc == AVCOL_TRC_SMPTE2084 ? 1 : 6) : 0;
  if (profile == 5) {
    parameters->color_primaries = AVCOL_PRI_BT2020;
    parameters->color_trc = AVCOL_TRC_SMPTE2084;
  }
  return 0;
}
}  // namespace rillight::core
