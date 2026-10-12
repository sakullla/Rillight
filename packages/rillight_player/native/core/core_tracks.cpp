#include "core_tracks.h"

namespace rillight::core {
bool bitmap_subtitle_codec(AVCodecID codec) {
  return codec == AV_CODEC_ID_HDMV_PGS_SUBTITLE ||
         codec == AV_CODEC_ID_DVB_SUBTITLE ||
         codec == AV_CODEC_ID_DVD_SUBTITLE || codec == AV_CODEC_ID_XSUB;
}

#if RILLIGHT_HAVE_LIBASS
bool text_subtitle_codec(AVCodecID codec) {
  return codec == AV_CODEC_ID_SUBRIP || codec == AV_CODEC_ID_WEBVTT ||
         codec == AV_CODEC_ID_MOV_TEXT;
}
#endif

void copy_field(char *destination, size_t capacity, const char *source) {
  if (!source) return;
  std::snprintf(destination, capacity, "%s", source);
}

uint32_t hardware_capabilities(AVCodecID codec_id) {
  uint32_t capabilities = 0;
  auto collect = [&capabilities](const AVCodec *decoder) {
    if (!decoder) return;
    for (int index = 0;; ++index) {
      const AVCodecHWConfig *config = avcodec_get_hw_config(decoder, index);
      if (!config) break;
      if (!(config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) continue;
      switch (config->device_type) {
        case AV_HWDEVICE_TYPE_D3D11VA:
          capabilities |= RILLIGHT_CORE_HW_D3D11;
          break;
        case AV_HWDEVICE_TYPE_VIDEOTOOLBOX:
          capabilities |= RILLIGHT_CORE_HW_VIDEOTOOLBOX;
          break;
        case AV_HWDEVICE_TYPE_VAAPI:
          capabilities |= RILLIGHT_CORE_HW_VAAPI;
          break;
        case AV_HWDEVICE_TYPE_MEDIACODEC:
          capabilities |= RILLIGHT_CORE_HW_MEDIACODEC;
          break;
        default:
          break;
      }
    }
  };
  collect(avcodec_find_decoder(codec_id));
  const char *name = mediacodec_decoder_name(codec_id);
  if (name) collect(avcodec_find_decoder_by_name(name));
  return capabilities;
}

RillightCoreTrack make_track(const AVStream *stream) {
  RillightCoreTrack track{};
  track.struct_size = sizeof(track);
  track.stream_index = stream->index;
  track.codec_id = static_cast<int>(stream->codecpar->codec_id);
  copy_field(track.codec_name, sizeof(track.codec_name),
             avcodec_get_name(stream->codecpar->codec_id));
  const AVDictionaryEntry *language = av_dict_get(stream->metadata,
                                                  "language", nullptr, 0);
  const AVDictionaryEntry *title = av_dict_get(stream->metadata,
                                               "title", nullptr, 0);
  copy_field(track.language, sizeof(track.language),
             language ? language->value : nullptr);
  copy_field(track.title, sizeof(track.title), title ? title->value : nullptr);
  track.is_default = (stream->disposition & AV_DISPOSITION_DEFAULT) != 0;
  switch (stream->codecpar->codec_type) {
    case AVMEDIA_TYPE_VIDEO:
      track.type = RILLIGHT_CORE_TRACK_VIDEO;
      track.width = stream->codecpar->width;
      track.height = stream->codecpar->height;
      track.decoder_hardware_capabilities =
          hardware_capabilities(stream->codecpar->codec_id);
      break;
    case AVMEDIA_TYPE_AUDIO:
      track.type = RILLIGHT_CORE_TRACK_AUDIO;
      track.sample_rate = stream->codecpar->sample_rate;
      track.channels = stream->codecpar->ch_layout.nb_channels;
      break;
    case AVMEDIA_TYPE_SUBTITLE:
      track.type = RILLIGHT_CORE_TRACK_SUBTITLE;
      break;
    default:
      break;
  }
  return track;
}
}  // namespace rillight::core
