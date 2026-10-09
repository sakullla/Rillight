#pragma once

#include <cstdint>
#include <vector>

struct SubtitleBitmap {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
  std::vector<uint8_t> indices;
  std::vector<uint32_t> palette;
};

struct SubtitleCue {
  int64_t start_us = 0;
  int64_t end_us = 0;
  std::vector<SubtitleBitmap> bitmaps;
  uint64_t identity = 0;
};

struct BitmapSubtitleKey {
  int width;
  int height;
  std::vector<uint64_t> cues;
  bool operator==(const BitmapSubtitleKey& other) const {
    return width == other.width && height == other.height && cues == other.cues;
  }
};

inline BitmapSubtitleKey bitmap_subtitle_key(
    const std::vector<SubtitleCue>& cues, int64_t pts_us, int width, int height) {
  BitmapSubtitleKey key{width, height, {}};
  for (const auto& cue : cues)
    if (cue.start_us <= pts_us && pts_us < cue.end_us)
      key.cues.push_back(cue.identity);
  return key;
}

// PGS display sets replace the previous composition, including empty sets
// that clear the screen. Keep earlier cues until presentation reaches this
// timestamp: the demuxer may decode subtitles ahead of displayed video.
inline void end_pgs_display(std::vector<SubtitleCue>& cues, int64_t next_us) {
  for (auto& cue : cues) {
    if (cue.start_us <= next_us && cue.end_us > next_us)
      cue.end_us = next_us;
  }
}
