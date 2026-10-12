#pragma once

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <string>

namespace rillight::core {
// Conversion time excludes queue/clock waits. Protected by the session mutex;
// reset on a timeline change so a seek/pause is not reported as slow mapping.
struct VideoProcessingDiagnostics {
  std::string path;
  uint64_t frames = 0;
  int64_t elapsed_us = 0;
  std::string summary;

  void Record(const char* route, bool downloaded, int64_t microseconds,
              const char* stage = "convert") {
    const std::string next = std::string(downloaded ? "download+" : "") + route;
    if (path != next) {
      *this = {};
      path = next;
    }
    ++frames;
    elapsed_us += std::max<int64_t>(0, microseconds);
    // A rolling bounded sample retains recent behavior without introducing a
    // new ABI field or changing a diagnostics string on every frame.
    if (summary.empty() || frames >= 30) {
      char text[96];
      std::snprintf(text, sizeof(text), "color=%s %s=%.1fms",
                    path.c_str(), stage, elapsed_us / (1000.0 * frames));
      summary = text;
      if (frames >= 30) { frames = 0; elapsed_us = 0; }
    }
  }
};
}  // namespace rillight::core
