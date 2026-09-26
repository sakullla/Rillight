#pragma once

#include "../../native/core/rillight_core.h"

namespace rillight_macos {

// A frame can be removed from the core queue before the next audio clock
// report. The sink keeps one reference and rechecks it against the snapshot.
inline bool VideoDue(const RillightCoreFrame& frame,
                     const RillightCoreSnapshot& snapshot) {
  return frame.pts_us < 0 || snapshot.state == RILLIGHT_CORE_READY ||
         frame.pts_us <= snapshot.position_us + 33000;
}

inline bool VideoTooLate(const RillightCoreFrame& frame,
                         const RillightCoreSnapshot& snapshot) {
  return snapshot.state == RILLIGHT_CORE_PLAYING && frame.pts_us >= 0 &&
         frame.pts_us < snapshot.position_us - 250000;
}

}  // namespace rillight_macos
