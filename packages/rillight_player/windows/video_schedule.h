#pragma once

#include "../native/core/rillight_core.h"

namespace rillight_windows {
inline bool VideoFrameDue(int64_t pts_us, const RillightCoreSnapshot& state) {
  // The core permits one preview after a paused open/seek. Its PTS can be the
  // first available picture after the requested position; a paused clock will
  // never advance to it. Present that preview without waiting for wall time.
  return pts_us < 0 || pts_us <= state.position_us + 10000 ||
      state.state == RILLIGHT_CORE_READY || state.state == RILLIGHT_CORE_PAUSED;
}
}  // namespace rillight_windows
