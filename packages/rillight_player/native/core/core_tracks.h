#pragma once

#include "core_decoder.h"

namespace rillight::core {
// core_tracks.cpp
bool bitmap_subtitle_codec(AVCodecID codec);
#if RILLIGHT_HAVE_LIBASS
bool text_subtitle_codec(AVCodecID codec);
#endif
void copy_field(char *destination, size_t capacity, const char *source);
uint32_t hardware_capabilities(AVCodecID codec_id);
RillightCoreTrack make_track(const AVStream *stream);
}  // namespace rillight::core
