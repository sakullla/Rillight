#include "core_state.h"
#include "core_tracks.h"
#include "core_video.h"

namespace rillight::core {
#if RILLIGHT_HAVE_LIBASS

void close_ass(AssRenderer *ass) {
  if (ass->track) ass_free_track(ass->track);
  if (ass->renderer) ass_renderer_done(ass->renderer);
  if (ass->library) ass_library_done(ass->library);
  *ass = {};
}

void configure_ass_fonts(ASS_Renderer *renderer) {
#if defined(__ANDROID__)
  // Android has no Fontconfig provider. Use a readable system font for text
  // subtitles and ASS scripts without an attached font.
  constexpr const char *fonts[] = {
      "/system/fonts/NotoSansCJK-Regular.ttc",
      "/system/fonts/Roboto-Regular.ttf",
      "/system/fonts/DroidSans.ttf",
  };
  const char *fallback = nullptr;
  for (const char *font : fonts) {
    if (access(font, R_OK) == 0) {
      fallback = font;
      break;
    }
  }
  ass_set_fonts(renderer, fallback, "sans-serif", ASS_FONTPROVIDER_NONE,
                nullptr, 1);
#else
  ass_set_fonts(renderer, nullptr, "sans-serif", ASS_FONTPROVIDER_AUTODETECT,
                nullptr, 1);
#endif
}

bool open_ass(AssRenderer *ass, AVFormatContext *format, int stream_index) {
  AssRenderer replacement;
  replacement.library = ass_library_init();
  if (!replacement.library) return false;
  replacement.renderer = ass_renderer_init(replacement.library);
  replacement.track = ass_new_track(replacement.library);
  if (!replacement.renderer || !replacement.track) {
    close_ass(&replacement);
    return false;
  }
  const auto *parameters = format->streams[stream_index]->codecpar;
  if (parameters->extradata && parameters->extradata_size > 0)
    ass_process_codec_private(replacement.track,
                              reinterpret_cast<const char *>(parameters->extradata),
                              parameters->extradata_size);
  for (unsigned int index = 0; index < format->nb_streams; ++index) {
    const AVStream *stream = format->streams[index];
    if (stream->codecpar->codec_type != AVMEDIA_TYPE_ATTACHMENT ||
        stream->codecpar->extradata_size <= 0 ||
        stream->codecpar->extradata_size > 8 * 1024 * 1024) continue;
    const AVDictionaryEntry *name = av_dict_get(stream->metadata,
                                                "filename", nullptr, 0);
    if (name && name->value)
      ass_add_font(replacement.library, name->value,
                   reinterpret_cast<const char *>(stream->codecpar->extradata),
                   stream->codecpar->extradata_size);
  }
  configure_ass_fonts(replacement.renderer);
  replacement.stream = stream_index;
  close_ass(ass);
  *ass = replacement;
  return true;
}

bool open_text_ass(AssRenderer *ass, const AVCodecContext *decoder,
                   int stream_index) {
  if (!decoder || !decoder->subtitle_header ||
      decoder->subtitle_header_size <= 0) return false;
  AssRenderer replacement;
  replacement.library = ass_library_init();
  if (!replacement.library) return false;
  replacement.renderer = ass_renderer_init(replacement.library);
  replacement.track = ass_new_track(replacement.library);
  if (!replacement.renderer || !replacement.track) {
    close_ass(&replacement);
    return false;
  }
  ass_process_codec_private(replacement.track,
                            reinterpret_cast<const char *>(
                                decoder->subtitle_header),
                            decoder->subtitle_header_size);
  configure_ass_fonts(replacement.renderer);
  replacement.stream = stream_index;
  replacement.plain_text = true;
  if (ass_track_set_feature(replacement.track, ASS_FEATURE_WRAP_UNICODE, 1) != 0) {
    close_ass(&replacement);
    return false;
  }
  close_ass(ass);
  *ass = replacement;
  return true;
}

int decode_text_subtitle(Decoder &decoder, const AVPacket *packet,
                         AVRational time_base, AssRenderer *ass,
                         int64_t origin_us) {
  AVSubtitle subtitle{};
  int got = 0;
  const int result = avcodec_decode_subtitle2(decoder.context, &subtitle,
                                               &got, packet);
  if (result < 0) return result;
  if (!got) return 0;
  int64_t start_ms = subtitle.pts == AV_NOPTS_VALUE ?
      (packet->pts == AV_NOPTS_VALUE ? 0 :
       av_rescale_q(packet->pts, time_base, AVRational{1, 1000})) :
      subtitle.pts / 1000;
  start_ms += subtitle.start_display_time;
  // Frame clocks are media-relative. Embedded cues must use the same origin.
  if (origin_us > 0) start_ms -= origin_us / 1000;
  int64_t duration_ms = 0;
  if (subtitle.end_display_time > subtitle.start_display_time)
    duration_ms = subtitle.end_display_time - subtitle.start_display_time;
  else if (packet->duration > 0)
    duration_ms = av_rescale_q(packet->duration, time_base,
                               AVRational{1, 1000});
  if (duration_ms <= 0) duration_ms = 5000;
  for (unsigned int index = 0; index < subtitle.num_rects; ++index) {
    const auto *rect = subtitle.rects[index];
    if (rect->type != SUBTITLE_ASS || !rect->ass) continue;
    ass_process_chunk(ass->track, rect->ass, std::strlen(rect->ass),
                      start_ms, duration_ms);
  }
  avsubtitle_free(&subtitle);
  return 0;
}

bool open_external_ass(AssRenderer *ass, const std::vector<char> &script,
                       int stream_index) {
  if (script.empty()) return false;
  AssRenderer replacement;
  replacement.library = ass_library_init();
  if (!replacement.library) return false;
  replacement.renderer = ass_renderer_init(replacement.library);
  std::vector<char> mutable_script = script;
  mutable_script.push_back('\0');
  replacement.track = ass_read_memory(replacement.library,
                                      mutable_script.data(), script.size(),
                                      nullptr);
  if (!replacement.renderer || !replacement.track ||
      replacement.track->n_events <= 0) {
    close_ass(&replacement);
    return false;
  }
  configure_ass_fonts(replacement.renderer);
  replacement.stream = stream_index;
  replacement.external = true;
  close_ass(ass);
  *ass = replacement;
  return true;
}

bool open_external_text(AssRenderer *ass, const std::vector<char> &header,
                        const std::vector<ExternalTextCue> &cues,
                        int stream_index) {
  if (header.empty() || cues.empty()) return false;
  AssRenderer replacement;
  replacement.library = ass_library_init();
  if (!replacement.library) return false;
  replacement.renderer = ass_renderer_init(replacement.library);
  replacement.track = ass_new_track(replacement.library);
  if (!replacement.renderer || !replacement.track) {
    close_ass(&replacement);
    return false;
  }
  ass_process_codec_private(replacement.track, header.data(), header.size());
  for (const auto &cue : cues) {
    std::string chunk = cue.ass_chunk;
    ass_process_chunk(replacement.track, chunk.data(), chunk.size(),
                      cue.start_ms, cue.duration_ms);
  }
  if (replacement.track->n_events <= 0) {
    close_ass(&replacement);
    return false;
  }
  configure_ass_fonts(replacement.renderer);
  replacement.stream = stream_index;
  replacement.plain_text = true;
  if (ass_track_set_feature(replacement.track, ASS_FEATURE_WRAP_UNICODE, 1) != 0) {
    close_ass(&replacement);
    return false;
  }
  replacement.external = true;
  close_ass(ass);
  *ass = replacement;
  return true;
}

void process_ass(AssRenderer *ass, const AVPacket *packet,
                 AVRational time_base, int64_t origin_us) {
  if (!ass->track || !packet->data || packet->size <= 0) return;
  int64_t start = packet->pts == AV_NOPTS_VALUE ? 0 :
      av_rescale_q(packet->pts, time_base, AVRational{1, 1000});
  if (origin_us > 0) start -= origin_us / 1000;
  const int64_t duration = packet->duration > 0 ?
      av_rescale_q(packet->duration, time_base, AVRational{1, 1000}) : 5000;
  ass_process_chunk(ass->track,
                    reinterpret_cast<char *>(packet->data), packet->size,
                    start, duration);
}

// Both output paths enter here, in the subtitle mutex, before rasterization.
void apply_subtitle_presentation(AssRenderer *ass, int width, int height,
                                const RillightCoreSubtitlePresentation &p) {
  if (!ass->track) return;
  if (ass->last_width == width && ass->last_height == height &&
      std::memcmp(&ass->last_presentation, &p, sizeof(p)) == 0) return;
  ass->last_presentation = p;
  ass->last_width = width; ass->last_height = height;
  ass_set_storage_size(ass->renderer, width, height);
  ass_set_frame_size(ass->renderer, width, height);
  ass_set_font_scale(ass->renderer, 1.0);
  ass_set_pixel_aspect(ass->renderer, 0);
  ass_set_selective_style_override_enabled(ass->renderer, ASS_OVERRIDE_DEFAULT);
  if (!p.enabled || (!ass->plain_text && p.original_ass)) return;
  ass_set_pixel_aspect(ass->renderer,
      (p.display_width / p.display_height) / (static_cast<double>(width) / height));
  // libass's selective user style uses a 288-high virtual canvas, independent
  // of the script PlayRes. Pixel aspect is kept at 1: no stretched glyphs.
  const double size = std::min(p.font_size * p.user_scale,
                               p.display_height * 0.18);
  ASS_Style style{};
  // libass 0.17.5 copies FontName even when only size fields are selected.
  style.FontName = const_cast<char *>("sans-serif");
  style.FontSize = size * 288.0 / p.display_height;
  style.ScaleX = style.ScaleY = 1.0;
  style.MarginL = style.MarginR = static_cast<int>(
      p.safe_horizontal * ass->track->PlayResX / p.display_width);
  style.MarginV = static_cast<int>(p.safe_vertical * ass->track->PlayResY / p.display_height);
  int bits = ASS_OVERRIDE_BIT_FONT_SIZE_FIELDS;
  if (ass->plain_text) bits |= ASS_OVERRIDE_BIT_MARGINS;
  ass_set_selective_style_override(ass->renderer, &style);
  ass_set_selective_style_override_enabled(ass->renderer, bits);
}

void blend_ass(RillightCoreFrame *frame, AssRenderer *ass) {
  if (!ass->track || !frame || frame->pts_us < 0) return;
  ass_set_storage_size(ass->renderer, frame->width, frame->height);
  ass_set_frame_size(ass->renderer, frame->width, frame->height);
  int changed = 0;
  const ASS_Image *image = ass_render_frame(ass->renderer, ass->track,
                                            frame->pts_us / 1000, &changed);
  for (; image; image = image->next) {
    if (!image->bitmap || image->w <= 0 || image->h <= 0 ||
        image->stride < image->w) continue;
    const uint32_t color = image->color;
    const unsigned int opacity = 255 - (color & 0xff);
    for (int row = 0; row < image->h; ++row) {
      const int y = image->dst_y + row;
      if (y < 0 || y >= frame->height) continue;
      for (int column = 0; column < image->w; ++column) {
        const int x = image->dst_x + column;
        if (x < 0 || x >= frame->width) continue;
        const unsigned int alpha =
            image->bitmap[static_cast<size_t>(row) * image->stride + column] *
            opacity / 255;
        if (!alpha) continue;
        uint8_t *pixel = frame->data + static_cast<size_t>(y) *
                                        frame->stride + x * 4;
        for (int channel = 0; channel < 3; ++channel) {
          const unsigned int foreground =
              (color >> (24 - channel * 8)) & 0xff;
          pixel[channel] = static_cast<uint8_t>(
              (foreground * alpha + pixel[channel] * (255 - alpha) + 127) /
              255);
        }
        pixel[3] = 255;
      }
    }
  }
}
#else

void close_ass(AssRenderer *) {}
void blend_ass(RillightCoreFrame *, AssRenderer *) {}
void apply_subtitle_presentation(AssRenderer *, int, int,
    const RillightCoreSubtitlePresentation &) {}
#endif

void blend_subtitles(RillightCoreFrame *frame,
                     const std::vector<SubtitleCue> &cues) {
  if (!frame || frame->type != RILLIGHT_CORE_VIDEO_RGBA || frame->pts_us < 0)
    return;
  for (const auto &cue : cues) {
    if (frame->pts_us < cue.start_us || frame->pts_us >= cue.end_us) continue;
    for (const auto &bitmap : cue.bitmaps) {
      for (int row = 0; row < bitmap.height; ++row) {
        const int y = bitmap.y + row;
        if (y < 0 || y >= frame->height) continue;
        for (int column = 0; column < bitmap.width; ++column) {
          const int x = bitmap.x + column;
          if (x < 0 || x >= frame->width) continue;
          const uint8_t index = bitmap.indices[
              static_cast<size_t>(row) * bitmap.width + column];
          if (index >= bitmap.palette.size()) continue;
          const uint32_t color = bitmap.palette[index];
          const unsigned int alpha = color >> 24;
          if (!alpha) continue;
          uint8_t *pixel = frame->data + static_cast<size_t>(y) *
                                          frame->stride + x * 4;
          for (int channel = 0; channel < 3; ++channel) {
            const unsigned int foreground =
                (color >> (16 - channel * 8)) & 0xff;
            pixel[channel] = static_cast<uint8_t>(
                (foreground * alpha + pixel[channel] * (255 - alpha) + 127) /
                255);
          }
          pixel[3] = 255;
        }
      }
    }
  }
}

void render_gpu_subtitles(VideoOutputFrame* frame,
                          const std::vector<SubtitleCue>& cues, AssRenderer* ass,
                          BitmapSubtitleOverlayCache* cache, AssRenderer* secondary,
                          const std::vector<SubtitleCue>* secondary_cues) {
  // Bitmap display sets remain unchanged across video frames. Share immutable
  // composed pixels until a cue changes; animated ASS must still render at PTS.
  bool cacheable = true;
#if RILLIGHT_HAVE_LIBASS
  cacheable = !ass->track && (!secondary || !secondary->track);
#endif
  auto key = bitmap_subtitle_key(cues, frame->pts_us, frame->width, frame->height);
  const std::vector<SubtitleCue> empty_cues;
  if (!secondary_cues) secondary_cues = &empty_cues;
  const auto secondary_key = bitmap_subtitle_key(*secondary_cues, frame->pts_us, frame->width, frame->height);
  key.cues.insert(key.cues.end(), secondary_key.cues.begin(), secondary_key.cues.end());
  if (cacheable && cache->valid && cache->key == key) {
    frame->subtitle_pixels = cache->pixels;
    frame->subtitle_overlay = cache->overlay;
    if (frame->subtitle_pixels)
      frame->data_size += static_cast<int>(frame->subtitle_pixels->size());
    return;
  }
  const auto remember = [&] {
    cache->valid = cacheable;
    cache->key = std::move(key);
    cache->pixels = cacheable ? frame->subtitle_pixels : nullptr;
    cache->overlay = cacheable ? frame->subtitle_overlay : RillightCoreSubtitleOverlay{};
  };
  int left = frame->width, top = frame->height, right = 0, bottom = 0;
  const auto include = [&](int x, int y, int width, int height) {
    if (width <= 0 || height <= 0) return;
    const int x0 = std::clamp(x, 0, frame->width);
    const int y0 = std::clamp(y, 0, frame->height);
    const int x1 = static_cast<int>(std::clamp<int64_t>(static_cast<int64_t>(x) + width, 0, frame->width));
    const int y1 = static_cast<int>(std::clamp<int64_t>(static_cast<int64_t>(y) + height, 0, frame->height));
    if (x0 >= x1 || y0 >= y1) return;
    left = std::min(left, x0); top = std::min(top, y0);
    right = std::max(right, x1); bottom = std::max(bottom, y1);
  };
  for (const auto* group : {&cues, secondary_cues})
  for (const auto& cue : *group) {
    if (frame->pts_us < cue.start_us || frame->pts_us >= cue.end_us) continue;
    for (const auto& bitmap : cue.bitmaps) include(bitmap.x, bitmap.y, bitmap.width, bitmap.height);
  }
#if RILLIGHT_HAVE_LIBASS
  const ASS_Image* images = nullptr;
  const ASS_Image* secondary_images = nullptr;
  if (secondary && secondary->track && frame->pts_us >= 0) {
    int changed = 0;
    secondary_images = ass_render_frame(secondary->renderer, secondary->track, frame->pts_us / 1000, &changed);
    for (auto* image = secondary_images; image; image = image->next)
      if (image->bitmap && image->stride >= image->w)
        include(image->dst_x, image->dst_y, image->w, image->h);
  }
  if (ass->track && frame->pts_us >= 0) {
    ass_set_storage_size(ass->renderer, frame->width, frame->height);
    ass_set_frame_size(ass->renderer, frame->width, frame->height);
    int changed = 0;
    images = ass_render_frame(ass->renderer, ass->track, frame->pts_us / 1000, &changed);
    for (auto* image = images; image; image = image->next)
      if (image->bitmap && image->stride >= image->w)
        include(image->dst_x, image->dst_y, image->w, image->h);
  }
#else
  (void)ass; (void)secondary;
#endif
  if (left >= right || top >= bottom) { remember(); return; }
  const int width = right - left, height = bottom - top;
  const size_t bytes = static_cast<size_t>(width) * height * 4;
  if (bytes > kMaxVideoBytes) return;
  frame->subtitle_pixels = std::make_shared<std::vector<uint8_t>>(bytes, 0);
  frame->subtitle_overlay = {sizeof(RillightCoreSubtitleOverlay), left, top, width, height, width * 4,
                             frame->subtitle_pixels->data()};
  frame->data_size += static_cast<int>(bytes);
  const auto blend = [&](int64_t x, int64_t y, unsigned int color, unsigned int alpha) {
    if (x < left || x >= right || y < top || y >= bottom || !alpha) return;
    auto* pixel = frame->subtitle_pixels->data() +
        (static_cast<size_t>(y - top) * width + static_cast<size_t>(x - left)) * 4;
    for (int channel = 0; channel < 3; ++channel) {
      const unsigned int foreground = (color >> (16 - channel * 8)) & 255;
      pixel[channel] = static_cast<uint8_t>((foreground * alpha + pixel[channel] * (255 - alpha) + 127) / 255);
    }
    pixel[3] = static_cast<uint8_t>(alpha + (pixel[3] * (255 - alpha) + 127) / 255);
  };
  for (const auto* group : {&cues, secondary_cues})
  for (const auto& cue : *group) {
    if (frame->pts_us < cue.start_us || frame->pts_us >= cue.end_us) continue;
    for (const auto& bitmap : cue.bitmaps) {
      for (int row = 0; row < bitmap.height; ++row) {
        for (int column = 0; column < bitmap.width; ++column) {
          const auto index = bitmap.indices[static_cast<size_t>(row) * bitmap.width + column];
          if (index >= bitmap.palette.size()) continue;
          const auto color = bitmap.palette[index];
          blend(static_cast<int64_t>(bitmap.x) + column, static_cast<int64_t>(bitmap.y) + row, color, color >> 24);
        }
      }
    }
  }
#if RILLIGHT_HAVE_LIBASS
  for (const auto* head : {images, secondary_images})
  for (auto* image = head; image; image = image->next) {
    if (!image->bitmap || image->w <= 0 || image->h <= 0 || image->stride < image->w) continue;
    const unsigned int opacity = 255 - (image->color & 255);
    for (int row = 0; row < image->h; ++row) {
      for (int column = 0; column < image->w; ++column) {
        const unsigned int alpha = image->bitmap[static_cast<size_t>(row) * image->stride + column] * opacity / 255;
        blend(static_cast<int64_t>(image->dst_x) + column, static_cast<int64_t>(image->dst_y) + row,
              image->color >> 8, alpha);
      }
    }
  }
#endif
  remember();
}

int decode_bitmap_subtitle(Decoder &decoder, const AVPacket *packet,
                           AVRational time_base,
                           std::vector<SubtitleCue> *cues,
                           int64_t origin_us) {
  AVSubtitle subtitle{};
  int got = 0;
  const int result = avcodec_decode_subtitle2(decoder.context, &subtitle,
                                               &got, packet);
  if (result < 0) return result;
  if (!got) return 0;
  int64_t start = subtitle.pts;
  if (start == AV_NOPTS_VALUE && packet->pts != AV_NOPTS_VALUE)
    start = av_rescale_q(packet->pts, time_base, AVRational{1, 1000000});
  if (start == AV_NOPTS_VALUE) start = 0;
  SubtitleCue cue;
  cue.start_us = start + subtitle.start_display_time * 1000LL - origin_us;
  cue.end_us = start + subtitle.end_display_time * 1000LL - origin_us;
  if (cue.end_us <= cue.start_us) cue.end_us = cue.start_us + 5000000;
  if (decoder.context->codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE)
    end_pgs_display(*cues, cue.start_us);
  size_t cue_bytes = 0;
  for (unsigned int index = 0; index < subtitle.num_rects; ++index) {
    const AVSubtitleRect *rect = subtitle.rects[index];
    if (rect->type != SUBTITLE_BITMAP || rect->w <= 0 || rect->h <= 0 ||
        rect->w > 8192 || rect->h > 8192 || !rect->data[0] ||
        !rect->data[1] || rect->linesize[0] < rect->w ||
        static_cast<size_t>(rect->w) * rect->h > 4u * 1024u * 1024u ||
        cue_bytes + static_cast<size_t>(rect->w) * rect->h >
            8u * 1024u * 1024u)
      continue;
    SubtitleBitmap bitmap;
    bitmap.x = rect->x;
    bitmap.y = rect->y;
    bitmap.width = rect->w;
    bitmap.height = rect->h;
    bitmap.indices.resize(static_cast<size_t>(rect->w) * rect->h);
    for (int row = 0; row < rect->h; ++row)
      std::memcpy(bitmap.indices.data() + static_cast<size_t>(row) * rect->w,
                  rect->data[0] + static_cast<size_t>(row) * rect->linesize[0],
                  rect->w);
    const int colors = std::clamp(rect->nb_colors, 0, 256);
    const auto *palette = reinterpret_cast<const uint32_t *>(rect->data[1]);
    bitmap.palette.assign(palette, palette + colors);
    cue_bytes += bitmap.indices.size();
    cue.bitmaps.push_back(std::move(bitmap));
  }
  avsubtitle_free(&subtitle);
  if (!cue.bitmaps.empty()) {
    static std::atomic<uint64_t> next_identity{0};
    cue.identity = next_identity.fetch_add(1, std::memory_order_relaxed) + 1;
    cues->push_back(std::move(cue));
    if (cues->size() > 8) cues->erase(cues->begin());
  }
  return 0;
}

#if RILLIGHT_HAVE_LIBASS
int read_external_ass(RillightCoreImpl *core, const std::string &url,
                      std::vector<char> *script) {
  void *handle = core->io.open(core->io.opaque, url.c_str(), AVIO_FLAG_READ);
  if (!handle) return AVERROR(ENOENT);
  std::vector<char> bytes;
  uint8_t buffer[kIoBufferSize];
  int result = 0;
  auto progress_deadline = Clock::now() + std::chrono::seconds(5);
  while (!core->stop) {
    const int count = core->io.read(core->io.opaque, handle, buffer,
                                    sizeof(buffer));
    if (count == AVERROR(EAGAIN) && Clock::now() < progress_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
      continue;
    }
    // AVIO returns AVERROR_EOF for a complete HTTP resource. The in-memory
    // test source returns zero, so accept both successful EOF forms.
    if (count == 0 || count == AVERROR_EOF) break;
    if (count < 0) { result = count; break; }
    if (count > static_cast<int>(sizeof(buffer))) {
      result = AVERROR(EINVAL);
      break;
    }
    if (bytes.size() + static_cast<size_t>(count) >
        kMaxExternalSubtitleBytes) {
      result = AVERROR(EFBIG);
      break;
    }
    bytes.insert(bytes.end(), reinterpret_cast<char *>(buffer),
                 reinterpret_cast<char *>(buffer) + count);
    progress_deadline = Clock::now() + std::chrono::seconds(5);
  }
  core->io.close(core->io.opaque, handle);
  if (core->stop) return AVERROR_EXIT;
  if (result < 0) return result;
  if (bytes.empty()) return AVERROR_INVALIDDATA;
  *script = std::move(bytes);
  return 0;
}

struct SubtitleMemoryInput {
  RillightCoreImpl *core;
  const std::vector<char> *bytes;
  size_t offset = 0;
};

int subtitle_memory_read(void *opaque, uint8_t *buffer, int size) {
  auto *input = static_cast<SubtitleMemoryInput *>(opaque);
  if (input->core->stop) return AVERROR_EXIT;
  const size_t count = std::min(static_cast<size_t>(size),
                                input->bytes->size() - input->offset);
  if (!count) return AVERROR_EOF;
  std::memcpy(buffer, input->bytes->data() + input->offset, count);
  input->offset += count;
  return static_cast<int>(count);
}

int64_t subtitle_memory_seek(void *opaque, int64_t offset, int whence) {
  auto *input = static_cast<SubtitleMemoryInput *>(opaque);
  if (input->core->stop) return AVERROR_EXIT;
  if ((whence & ~AVSEEK_FORCE) == AVSEEK_SIZE)
    return static_cast<int64_t>(input->bytes->size());
  int64_t base = 0;
  switch (whence & ~AVSEEK_FORCE) {
    case SEEK_CUR: base = static_cast<int64_t>(input->offset); break;
    case SEEK_END: base = static_cast<int64_t>(input->bytes->size()); break;
    case SEEK_SET: break;
    default: return AVERROR(EINVAL);
  }
  if ((offset < 0 && offset < -base) ||
      (offset > 0 && base > INT64_MAX - offset)) return AVERROR(EINVAL);
  const int64_t target = base + offset;
  if (target < 0 || target > static_cast<int64_t>(input->bytes->size()))
    return AVERROR(EINVAL);
  input->offset = static_cast<size_t>(target);
  return target;
}

int parse_external_text(RillightCoreImpl *core,
                        const std::vector<char> &bytes, AVCodecID codec,
                        std::vector<char> *header,
                        std::vector<ExternalTextCue> *cues) {
  const char *name = codec == AV_CODEC_ID_SUBRIP ? "srt" :
                     codec == AV_CODEC_ID_WEBVTT ? "webvtt" : nullptr;
  if (!name || bytes.empty()) return AVERROR(EINVAL);
  const AVInputFormat *input_format = av_find_input_format(name);
  const AVCodec *avcodec = avcodec_find_decoder(codec);
  if (!input_format || !avcodec) return AVERROR_DECODER_NOT_FOUND;
  SubtitleMemoryInput input{core, &bytes};
  auto *buffer = static_cast<uint8_t *>(av_malloc(kIoBufferSize));
  if (!buffer) return AVERROR(ENOMEM);
  AVIOContext *avio = avio_alloc_context(buffer, kIoBufferSize, 0, &input,
                                        subtitle_memory_read, nullptr,
                                        subtitle_memory_seek);
  if (!avio) { av_free(buffer); return AVERROR(ENOMEM); }
  AVFormatContext *format = avformat_alloc_context();
  AVCodecContext *decoder = nullptr;
  AVPacket *packet = nullptr;
  int result = AVERROR(ENOMEM);
  if (!format) goto finish_external_text;
  format->pb = avio;
  format->flags |= AVFMT_FLAG_CUSTOM_IO;
  result = avformat_open_input(&format, nullptr, input_format, nullptr);
  if (result < 0) goto finish_external_text;
  result = avformat_find_stream_info(format, nullptr);
  if (result < 0) goto finish_external_text;
  {
    const int stream_index = av_find_best_stream(format,
        AVMEDIA_TYPE_SUBTITLE, -1, -1, nullptr, 0);
    if (stream_index < 0) { result = stream_index; goto finish_external_text; }
    const AVStream *stream = format->streams[stream_index];
    if (stream->codecpar->codec_id != codec) {
      result = AVERROR_INVALIDDATA;
      goto finish_external_text;
    }
    decoder = avcodec_alloc_context3(avcodec);
    if (!decoder) { result = AVERROR(ENOMEM); goto finish_external_text; }
    result = avcodec_parameters_to_context(decoder, stream->codecpar);
    if (result < 0) goto finish_external_text;
    decoder->pkt_timebase = stream->time_base;
    result = avcodec_open2(decoder, avcodec, nullptr);
    if (result < 0) goto finish_external_text;
    if (!decoder->subtitle_header || decoder->subtitle_header_size <= 0) {
      result = AVERROR_INVALIDDATA;
      goto finish_external_text;
    }
    header->assign(decoder->subtitle_header,
                   decoder->subtitle_header + decoder->subtitle_header_size);
    packet = av_packet_alloc();
    if (!packet) { result = AVERROR(ENOMEM); goto finish_external_text; }
    size_t total_chunk_bytes = header->size();
    while ((result = av_read_frame(format, packet)) >= 0) {
      if (core->stop) { result = AVERROR_EXIT; break; }
      if (packet->stream_index == stream_index) {
        AVSubtitle subtitle{};
        int got = 0;
        const int decoded = avcodec_decode_subtitle2(decoder, &subtitle,
                                                     &got, packet);
        if (decoded < 0) {
          avsubtitle_free(&subtitle);
          result = decoded;
          break;
        }
        if (got) {
          int64_t start_ms = subtitle.pts == AV_NOPTS_VALUE ?
              (packet->pts == AV_NOPTS_VALUE ? 0 :
               av_rescale_q(packet->pts, stream->time_base,
                            AVRational{1, 1000})) : subtitle.pts / 1000;
          start_ms += subtitle.start_display_time;
          int64_t duration_ms = subtitle.end_display_time >
                                subtitle.start_display_time ?
              subtitle.end_display_time - subtitle.start_display_time :
              av_rescale_q(packet->duration, stream->time_base,
                           AVRational{1, 1000});
          if (start_ms < 0 || duration_ms <= 0) {
            avsubtitle_free(&subtitle);
            result = AVERROR_INVALIDDATA;
            break;
          }
          for (unsigned int index = 0; index < subtitle.num_rects; ++index) {
            const AVSubtitleRect *rect = subtitle.rects[index];
            if (rect->type != SUBTITLE_ASS || !rect->ass) continue;
            const size_t length = std::strlen(rect->ass);
            if (cues->size() >= 10000 ||
                length > kMaxExternalSubtitleBytes - total_chunk_bytes) {
              result = AVERROR(EFBIG);
              break;
            }
            cues->push_back({start_ms, duration_ms, rect->ass});
            total_chunk_bytes += length;
          }
        }
        avsubtitle_free(&subtitle);
      }
      av_packet_unref(packet);
      if (result < 0) break;
    }
    if (result == AVERROR_EOF && !cues->empty()) result = 0;
    else if (result == AVERROR_EOF) result = AVERROR_INVALIDDATA;
  }
finish_external_text:
  av_packet_free(&packet);
  avcodec_free_context(&decoder);
  if (format) avformat_close_input(&format);
  if (avio) av_freep(&avio->buffer);
  avio_context_free(&avio);
  return result;
}

AVCodecID external_subtitle_codec(const std::string &url) {
  std::string path = url.substr(0, url.find_first_of("?#"));
  std::transform(path.begin(), path.end(), path.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  const auto ends_with = [&path](const char *suffix) {
    const size_t length = std::strlen(suffix);
    return path.size() >= length &&
           path.compare(path.size() - length, length, suffix) == 0;
  };
  if (ends_with(".srt")) return AV_CODEC_ID_SUBRIP;
  if (ends_with(".vtt") || ends_with(".webvtt")) return AV_CODEC_ID_WEBVTT;
  return AV_CODEC_ID_ASS;
}

void load_external_ass(RillightCoreImpl *core, uint64_t session,
                       std::string url) {
  std::vector<char> source;
  int result = read_external_ass(core, url, &source);
  const size_t source_bytes = source.size();
  const AVCodecID codec = external_subtitle_codec(url);
  std::vector<char> script;
  std::vector<ExternalTextCue> cues;
  if (result >= 0) {
    if (codec == AV_CODEC_ID_ASS) script = std::move(source);
    else result = parse_external_text(core, source, codec, &script, &cues);
  }
  if (result >= 0) {
    AssRenderer probe;
    const bool valid = codec == AV_CODEC_ID_ASS ?
        open_external_ass(&probe, script, -1) :
        open_external_text(&probe, script, cues, -1);
    if (!valid)
      result = AVERROR_INVALIDDATA;
    close_ass(&probe);
  }
  {
    std::lock_guard lock(core->mutex);
    if (core->stop || core->session != session) return;
    if (result >= 0 &&
        (core->external_subtitles.size() >= kMaxExternalSubtitleTracks ||
         core->external_subtitle_bytes + source_bytes >
             kMaxExternalSubtitleTotalBytes ||
         core->embedded_stream_count >= kExternalSubtitleStreamBase))
      result = AVERROR(EFBIG);
    if (result >= 0) {
      const int index = kExternalSubtitleStreamBase +
          static_cast<int>(core->external_subtitles.size());
      RillightCoreTrack track{};
      track.struct_size = sizeof(track);
      track.stream_index = index;
      track.type = RILLIGHT_CORE_TRACK_SUBTITLE;
      track.codec_id = codec;
      std::snprintf(track.codec_name, sizeof(track.codec_name), "%s",
                    avcodec_get_name(codec));
      std::snprintf(track.title, sizeof(track.title), "External %s",
                    codec == AV_CODEC_ID_ASS ? "ASS" :
                    codec == AV_CODEC_ID_SUBRIP ? "SRT" : "WebVTT");
      track.is_external = 1;
      core->tracks.push_back(track);
      core->external_subtitle_bytes += source_bytes;
      core->external_subtitles.push_back(
          {index, codec,
           std::make_shared<const std::vector<char>>(std::move(script)),
           std::make_shared<const std::vector<ExternalTextCue>>(std::move(cues)),
           source_bytes});
    }
    core->error = result;
    core->external_subtitle_pending = false;
    core->requested_external_subtitle.clear();
  }
  core->wake.notify_all();
}
#endif
}  // namespace rillight::core
