#ifndef RILLIGHT_VIDEO_ENHANCER_H_
#define RILLIGHT_VIDEO_ENHANCER_H_

#include "rillight_core.h"

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <vector>

namespace rillight {

struct QualityProcessResult {
  bool changed = false;
  bool has_midpoint = false;
  std::vector<uint8_t> current;
  int width = 0;
  int height = 0;
  int stride = 0;
  std::vector<uint8_t> midpoint;
  int mid_width = 0;
  int mid_height = 0;
  int mid_stride = 0;
  int64_t mid_pts_us = -1;
};

// Reconstructed pictures only. Subtitle overlays are not an input.
// Interpolation is RIFE v4.6. Anime4K is the upstream v4.0.1 GLSL chain.
// Super-resolution is realesr-general-x4v3 reduced to 2x.
// A stage stays inactive until that algorithm actually runs.
class VideoQualityEnhancer {
 public:
  struct Image {
    std::vector<float> rgb;
    std::vector<float> alpha;
    int width = 0;
    int height = 0;
    int64_t pts_us = -1;
    uint64_t timeline = 0;
    bool valid = false;
  };

  int Configure(const RillightCoreEnhancementRequest& request);
  void ResetSession();
  void ResetTemporal();
  void UpdatePlaybackFacts(int native_dolby, double source_frame_rate);
  void SetPictureAvailable(int available);
  void ApplyLoad(int drop_interpolation, int drop_scale, int drop_spatial);
  int NoteDeadline(int met, int64_t monotonic_us);
  RillightCoreEnhancementStatus Status() const;
  bool NeedsReconstructedPicture() const;
  // User request that still needs pixels, ignoring overload drops.
  bool RequestsPicture() const;
  bool Process(const uint8_t* src, int width, int height, int stride,
               int bytes_per_pixel, int64_t pts_us, uint64_t timeline,
               const uint8_t* previous, int previous_stride, size_t max_bytes,
               QualityProcessResult* result);

 private:
  bool SameRequest(const RillightCoreEnhancementRequest& request) const;
  bool PictureWork(int drop_interpolation, int drop_scale, int drop_spatial,
                   int scale_capacity) const;
  void Recompute();
  Image Decode(const uint8_t* src, int width, int height, int stride,
               int bytes_per_pixel) const;
  Image Filter(Image image, bool allow_scale, float ceiling) const;
  static bool HardCut(const Image& prior, const Image& current);

  RillightCoreEnhancementRequest request_{};
  RillightCoreEnhancementFacts facts_{};
  RillightCoreEnhancementStatus status_{};
  int drop_interpolation_ = 0;
  int drop_scale_ = 0;
  int drop_spatial_ = 0;
  int scale_capacity_ = 0;
  bool configured_ = false;
  bool miss_valid_ = false;
  int64_t miss_origin_us_ = 0;
  int64_t last_note_us_ = -1;
  Image retained_;
  mutable std::mutex mutex_;
};

RillightCoreEnhancementStatus ResolveEnhancement(
    const RillightCoreEnhancementRequest& request,
    const RillightCoreEnhancementFacts& facts, int drop_interpolation,
    int drop_scale, int drop_spatial, int scale_capacity);

}  // namespace rillight

#endif
