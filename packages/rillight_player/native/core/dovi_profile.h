#ifndef RILLIGHT_DOVI_PROFILE_H_
#define RILLIGHT_DOVI_PROFILE_H_
#include <cstdint>
#include "rillight_core.h"
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

// Open accepts Profile 5 without an enhancement layer, Profile 7 compatibility
// 6, and Profile 8 compatibility 1, 2, 4 or 6. Every other combination is
// unsupported. Profile 5 still has no HDR10 or YUV base.
inline int dovi_open_rejected(int profile, int compatibility, int el_present) {
  if (profile < 0) return 0;
  if (profile == 5) return el_present ? 1 : 0;
  if (profile == 7) return compatibility == 6 ? 0 : 1;
  if (profile == 8)
    return compatibility == 1 || compatibility == 2 || compatibility == 4 ||
                   compatibility == 6
               ? 0
               : 1;
  return 1;
}

struct DoviFrameDecision {
  int error = 0;
  int use_rpu = 0;
  int emit_picture = 1;
  int reconstruction = RILLIGHT_CORE_DOVI_RECON_NONE;
};

// rpu_usable, residual and composed are 0 or 1. Profile 5 never emits a
// picture when its RPU is missing or unusable, and never as ordinary HDR10.
// A residual that was not composed is a base-layer fallback, not FEL.
inline DoviFrameDecision dovi_frame_decision(int profile, int compatibility,
                                            int el_present, int rpu_usable,
                                            int residual, int composed) {
  DoviFrameDecision decision;
  if (profile < 0) {
    if (rpu_usable && !residual) {
      decision.use_rpu = 1;
      decision.reconstruction = RILLIGHT_CORE_DOVI_RECON_RPU;
    }
    return decision;
  }
  if (dovi_open_rejected(profile, compatibility, el_present)) {
    decision.error = RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI;
    decision.emit_picture = 0;
    return decision;
  }
  if (profile == 5) {
    if (!rpu_usable || residual) {
      decision.error = RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI;
      decision.emit_picture = 0;
      return decision;
    }
    decision.use_rpu = 1;
    decision.reconstruction = RILLIGHT_CORE_DOVI_RECON_RPU;
    return decision;
  }
  if (residual) {
    if (composed && rpu_usable) {
      decision.use_rpu = 1;
      decision.reconstruction = RILLIGHT_CORE_DOVI_RECON_FEL;
      return decision;
    }
    decision.reconstruction = RILLIGHT_CORE_DOVI_RECON_BASE_FALLBACK;
    return decision;
  }
  if (rpu_usable) {
    decision.use_rpu = 1;
    decision.reconstruction = RILLIGHT_CORE_DOVI_RECON_RPU;
    return decision;
  }
  decision.reconstruction = RILLIGHT_CORE_DOVI_RECON_BASE_FALLBACK;
  return decision;
}

// Native Dolby is only an Android MediaCodec frame whose decoder selected
// video/dolby-vision. scRGB (D3D11 + windows_scrgb), EDR (RGBA16F) and SDR
// RGBA stay non-Dolby even if android_dolby_mime is set.
inline int dovi_present_output_kind(int frame_type, int windows_scrgb,
                                   int macos_edr, int android_dolby_mime) {
  (void)macos_edr;
  if (frame_type == RILLIGHT_CORE_VIDEO_MEDIACODEC && android_dolby_mime)
    return RILLIGHT_CORE_VIDEO_OUT_DOLBY_VISION;
  if (frame_type == RILLIGHT_CORE_VIDEO_MEDIACODEC ||
      frame_type == RILLIGHT_CORE_VIDEO_ANDROID_P010)
    return RILLIGHT_CORE_VIDEO_OUT_UNKNOWN;
  if (frame_type == RILLIGHT_CORE_VIDEO_D3D11 && windows_scrgb)
    return RILLIGHT_CORE_VIDEO_OUT_HDR;
  if (frame_type == RILLIGHT_CORE_VIDEO_RGBA16F)
    return RILLIGHT_CORE_VIDEO_OUT_HDR;
  if (frame_type == RILLIGHT_CORE_VIDEO_RGBA ||
      frame_type == RILLIGHT_CORE_VIDEO_D3D11)
    return RILLIGHT_CORE_VIDEO_OUT_SDR;
  return RILLIGHT_CORE_VIDEO_OUT_UNKNOWN;
}

// GLES BT.2020 PQ is HDR. An 8-bit fallback is SDR. Neither is native Dolby.
inline int dovi_android_color_output_kind(int pq_selected) {
  return pq_selected ? RILLIGHT_CORE_VIDEO_OUT_HDR : RILLIGHT_CORE_VIDEO_OUT_SDR;
}
#endif
