#pragma once

#include "core_frames.h"

namespace rillight::core {
#if RILLIGHT_HAVE_LIBASS
struct ExternalTextCue {
  int64_t start_ms = 0;
  int64_t duration_ms = 0;
  std::string ass_chunk;
};

struct ExternalSubtitle {
  int stream_index = -1;
  AVCodecID codec = AV_CODEC_ID_NONE;
  std::shared_ptr<const std::vector<char>> script;
  std::shared_ptr<const std::vector<ExternalTextCue>> cues;
  size_t source_bytes = 0;
};

struct AssRenderer {
  ASS_Library *library = nullptr;
  ASS_Renderer *renderer = nullptr;
  ASS_Track *track = nullptr;
  int stream = -1;
  bool external = false;
  bool plain_text = false;
  RillightCoreSubtitlePresentation last_presentation{};
  int last_width = 0, last_height = 0;
};
#else
struct AssRenderer {};
#endif

struct RillightCoreImpl;
// core_subtitles.cpp
void close_ass(AssRenderer *ass);
#if RILLIGHT_HAVE_LIBASS
void configure_ass_fonts(ASS_Renderer *renderer);
bool open_ass(AssRenderer *ass, AVFormatContext *format, int stream_index);
bool open_text_ass(AssRenderer *ass, const AVCodecContext *decoder,
                   int stream_index);
int decode_text_subtitle(Decoder &decoder, const AVPacket *packet,
                         AVRational time_base, AssRenderer *ass,
                         int64_t origin_us = 0);
bool open_external_ass(AssRenderer *ass, const std::vector<char> &script,
                       int stream_index);
bool open_external_text(AssRenderer *ass, const std::vector<char> &header,
                        const std::vector<ExternalTextCue> &cues,
                        int stream_index);
void process_ass(AssRenderer *ass, const AVPacket *packet,
                 AVRational time_base, int64_t origin_us = 0);
#endif
void apply_subtitle_presentation(AssRenderer *ass, int width, int height,
                                const RillightCoreSubtitlePresentation &p);
void blend_ass(RillightCoreFrame *frame, AssRenderer *ass);
void blend_subtitles(RillightCoreFrame *frame,
                     const std::vector<SubtitleCue> &cues);
void render_gpu_subtitles(VideoOutputFrame* frame,
                          const std::vector<SubtitleCue>& cues, AssRenderer* ass,
                          BitmapSubtitleOverlayCache* cache, AssRenderer* secondary = nullptr,
                          const std::vector<SubtitleCue>* secondary_cues = nullptr);
int decode_bitmap_subtitle(Decoder &decoder, const AVPacket *packet,
                           AVRational time_base,
                           std::vector<SubtitleCue> *cues,
                           int64_t origin_us = 0);
#if RILLIGHT_HAVE_LIBASS
int read_external_ass(RillightCoreImpl *core, const std::string &url,
                      std::vector<char> *script);
int subtitle_memory_read(void *opaque, uint8_t *buffer, int size);
int64_t subtitle_memory_seek(void *opaque, int64_t offset, int whence);
int parse_external_text(RillightCoreImpl *core,
                        const std::vector<char> &bytes, AVCodecID codec,
                        std::vector<char> *header,
                        std::vector<ExternalTextCue> *cues);
AVCodecID external_subtitle_codec(const std::string &url);
void load_external_ass(RillightCoreImpl *core, uint64_t session,
                       std::string url);
#endif
}  // namespace rillight::core
