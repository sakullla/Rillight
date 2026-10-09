#include "../core/bitmap_subtitle.h"

#include <cassert>
#include <climits>

static int visible(const std::vector<SubtitleCue>& cues, int64_t time) {
  int count = 0;
  for (const auto& cue : cues)
    if (cue.start_us <= time && time < cue.end_us) ++count;
  return count;
}

int main() {
  // PGS reports an open-ended display until the next display set arrives.
  std::vector<SubtitleCue> cues{{1000000, INT64_MAX, {}}};
  end_pgs_display(cues, 3000000);
  cues.push_back({3000000, INT64_MAX, {}});
  assert(visible(cues, 2000000) == 1); // Decoding ahead preserves old frames.
  assert(visible(cues, 3000000) == 1); // New text replaces rather than overlaps.

  end_pgs_display(cues, 4000000); // Empty display set: no new bitmap to append.
  assert(visible(cues, 3999999) == 1);
  assert(visible(cues, 4000000) == 0);
  assert(visible(cues, 5000000) == 0);

  cues.push_back({6000000, 6500000, {}});
  end_pgs_display(cues, 7000000);
  assert(visible(cues, 6600000) == 0); // Never extend a bounded cue.
  end_pgs_display(cues, 5000000);
  assert(visible(cues, 6200000) == 1); // Earlier events leave future cues alone.
  end_pgs_display(cues, 6000000);
  assert(visible(cues, 6000000) == 0); // Same-timestamp replacement.

  std::vector<SubtitleCue> displayed{{100, 200, {}, 1}, {200, 300, {}, 2}};
  const auto first = bitmap_subtitle_key(displayed, 100, 1920, 1080);
  assert(first == bitmap_subtitle_key(displayed, 199, 1920, 1080));
  assert(!(first == bitmap_subtitle_key(displayed, 200, 1920, 1080)));
  assert(!(first == bitmap_subtitle_key(displayed, 300, 1920, 1080)));
  assert(!(first == bitmap_subtitle_key(displayed, 100, 1280, 720)));
  // A new track or seek can reuse timestamps with different bitmap content.
  displayed[0].identity = 3;
  assert(!(first == bitmap_subtitle_key(displayed, 100, 1920, 1080)));
}
