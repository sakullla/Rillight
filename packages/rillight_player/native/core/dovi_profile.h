#ifndef RILLIGHT_DOVI_PROFILE_H_
#define RILLIGHT_DOVI_PROFILE_H_
#include <cstdint>
extern "C" {
#include <libavutil/dovi_meta.h>
#include <libavutil/frame.h>
}

inline bool android_dovi_profile_supported(unsigned profile, uint32_t profiles) {
  return profile > 0 && profile <= 9 && (profiles & (1u << profile));
}

// The same header rules as FFmpeg ff_dovi_guess_profile_hevc. A container tag
// alone cannot distinguish an IPT Profile 5 base from a compatible HDR10 base.
inline int dovi_profile_from_frame(const AVFrame* frame) {
  const auto* side = frame ? av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA) : nullptr;
  if (!side || side->size < sizeof(AVDOVIMetadata)) return 0;
  const auto* header = av_dovi_get_header(reinterpret_cast<const AVDOVIMetadata*>(side->data));
  if (header->vdr_rpu_profile == 0 && header->bl_video_full_range_flag) return 5;
  if (header->vdr_rpu_profile == 1) {
    if (header->el_spatial_resampling_filter_flag && !header->disable_residual_flag)
      return header->vdr_bit_depth == 12 ? 7 : 4;
    return 8;
  }
  return 0;
}
#endif
