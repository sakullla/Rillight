#include "video_enhancer.h"

#include "anime4k_glsl.h"
#include "enhancement_models.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <mutex>
#include <utility>

namespace rillight {
namespace {

constexpr float kHardCut = 0.16f;

float HalfToFloat(uint16_t value) {
  const uint32_t sign = static_cast<uint32_t>(value & 0x8000u) << 16;
  const uint32_t exponent = (value >> 10) & 0x1fu;
  uint32_t fraction = value & 0x3ffu;
  uint32_t bits = 0;
  if (exponent == 0) {
    if (fraction == 0) {
      bits = sign;
    } else {
      int shift = 0;
      while ((fraction & 0x400u) == 0) {
        fraction <<= 1;
        ++shift;
      }
      fraction &= 0x3ffu;
      const uint32_t exp = static_cast<uint32_t>(127 - 14 - shift);
      bits = sign | (exp << 23) | (fraction << 13);
    }
  } else if (exponent == 31) {
    bits = sign | (0xffu << 23) | (fraction << 13);
  } else {
    bits = sign | ((exponent + (127 - 15)) << 23) | (fraction << 13);
  }
  float out = 0;
  std::memcpy(&out, &bits, sizeof(out));
  return out;
}

uint16_t FloatToHalf(float value) {
  uint32_t bits = 0;
  std::memcpy(&bits, &value, sizeof(bits));
  const uint32_t sign = (bits >> 16) & 0x8000u;
  int exponent = static_cast<int>((bits >> 23) & 0xffu) - 127 + 15;
  uint32_t fraction = bits & 0x7fffffu;
  if (exponent <= 0) {
    if (exponent < -10) return static_cast<uint16_t>(sign);
    fraction |= 0x800000u;
    const uint32_t shift = static_cast<uint32_t>(1 - exponent);
    uint32_t half = fraction >> (shift + 13);
    if (((fraction >> (shift + 12)) & 1u) != 0) ++half;
    return static_cast<uint16_t>(sign | half);
  }
  if (exponent >= 31) return static_cast<uint16_t>(sign | 0x7c00u);
  uint32_t half = (static_cast<uint32_t>(exponent) << 10) | (fraction >> 13);
  if ((fraction & 0x1000u) != 0) ++half;
  return static_cast<uint16_t>(sign | half);
}

float Luma(float r, float g, float b) {
  return (0.2126f * r) + (0.7152f * g) + (0.0722f * b);
}

int ClampByte(float value) {
  const float clamped = std::clamp(value, 0.0f, 1.0f);
  return static_cast<int>(std::lround(clamped * 255.0f));
}

bool ValidRequest(const RillightCoreEnhancementRequest& request) {
  if (request.struct_size != sizeof(request)) return false;
  if (request.interpolation != 0 && request.interpolation != 2) return false;
  if (request.anime4k < 0 || request.anime4k > 2) return false;
  if (request.super_resolution != 0 && request.super_resolution != 2) return false;
  if (request.anime4k != 0 && request.super_resolution != 0) return false;
  if (request.denoise < 0 || request.denoise > 100) return false;
  if (request.sharpen < 0 || request.sharpen > 100) return false;
  if (request.accept_leave_native_dolby != 0 &&
      request.accept_leave_native_dolby != 1)
    return false;
  if (request.display_refresh_hz < 0 || request.display_refresh_hz > 1000)
    return false;
  return true;
}

double SanitizedRate(double rate) {
  if (!std::isfinite(rate) || rate <= 0.0 || rate > 240.0) return 0.0;
  return rate;
}

void Denoise(VideoQualityEnhancer::Image* image, int strength) {
  const int width = image->width;
  const int height = image->height;
  const float sigma = 0.03f + (static_cast<float>(strength) / 100.0f) * 0.22f;
  const float inv = 1.0f / (2.0f * sigma * sigma);
  std::vector<float> out(image->rgb.size());
  static const int kDx[9] = {-1, 0, 1, -1, 0, 1, -1, 0, 1};
  static const int kDy[9] = {-1, -1, -1, 0, 0, 0, 1, 1, 1};
  static const float kSpatial[9] = {1, 2, 1, 2, 4, 2, 1, 2, 1};
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const int center = (y * width + x) * 3;
      float sum_r = 0, sum_g = 0, sum_b = 0, sum_w = 0;
      for (int neighbor = 0; neighbor < 9; ++neighbor) {
        const int nx = std::clamp(x + kDx[neighbor], 0, width - 1);
        const int ny = std::clamp(y + kDy[neighbor], 0, height - 1);
        const int index = (ny * width + nx) * 3;
        const float dr = image->rgb[static_cast<size_t>(index)] -
                         image->rgb[static_cast<size_t>(center)];
        const float dg = image->rgb[static_cast<size_t>(index + 1)] -
                         image->rgb[static_cast<size_t>(center + 1)];
        const float db = image->rgb[static_cast<size_t>(index + 2)] -
                         image->rgb[static_cast<size_t>(center + 2)];
        const float weight =
            kSpatial[neighbor] * std::exp(-(dr * dr + dg * dg + db * db) * inv);
        sum_r += weight * image->rgb[static_cast<size_t>(index)];
        sum_g += weight * image->rgb[static_cast<size_t>(index + 1)];
        sum_b += weight * image->rgb[static_cast<size_t>(index + 2)];
        sum_w += weight;
      }
      out[static_cast<size_t>(center)] = sum_r / sum_w;
      out[static_cast<size_t>(center + 1)] = sum_g / sum_w;
      out[static_cast<size_t>(center + 2)] = sum_b / sum_w;
    }
  }
  image->rgb.swap(out);
}

void Sharpen(VideoQualityEnhancer::Image* image, int strength, float ceiling) {
  const int width = image->width;
  const int height = image->height;
  const float amount = (static_cast<float>(strength) / 100.0f) * 1.2f;
  // A separable 3x3 box needs three scanlines, rather than nine RGB reads
  // per pixel and a second full-frame pass to apply the unsharp mask.
  const size_t row_size = static_cast<size_t>(width) * 3;
  std::vector<float> rows(row_size * 3);
  std::vector<float> out(image->rgb.size());
  auto horizontal = [&](int y) {
    const float* source = image->rgb.data() + static_cast<size_t>(y) * row_size;
    float* dest = rows.data() + static_cast<size_t>(y % 3) * row_size;
    for (int x = 0; x < width; ++x) {
      const int left = std::max(0, x - 1) * 3;
      const int right = std::min(width - 1, x + 1) * 3;
      for (int c = 0; c < 3; ++c)
        dest[x * 3 + c] = source[left + c] + source[x * 3 + c] + source[right + c];
    }
  };
  horizontal(0);
  for (int y = 0; y < height; ++y) {
    if (y + 1 < height) horizontal(y + 1);
    const float* above = rows.data() + static_cast<size_t>(std::max(0, y - 1) % 3) * row_size;
    const float* center = rows.data() + static_cast<size_t>(y % 3) * row_size;
    const float* below = rows.data() + static_cast<size_t>(std::min(height - 1, y + 1) % 3) * row_size;
    const size_t offset = static_cast<size_t>(y) * row_size;
    for (size_t x = 0; x < row_size; ++x) {
      const float blur = (above[x] + center[x] + below[x]) / 9.0f;
      const float value = image->rgb[offset + x];
      out[offset + x] = std::clamp(value + amount * (value - blur), 0.0f, ceiling);
    }
  }
  image->rgb.swap(out);
}

void Encode(const VideoQualityEnhancer::Image& image, int bytes_per_pixel,
            float ceiling, std::vector<uint8_t>* bytes, int* stride) {
  *stride = image.width * bytes_per_pixel;
  bytes->assign(static_cast<size_t>(*stride * image.height), 0);
  for (int y = 0; y < image.height; ++y) {
    for (int x = 0; x < image.width; ++x) {
      const size_t pixel = static_cast<size_t>(y * image.width + x);
      const size_t rgb = pixel * 3;
      uint8_t* dest = bytes->data() + static_cast<size_t>(y * *stride + x * bytes_per_pixel);
      const float channels[4] = {
          std::clamp(image.rgb[rgb], 0.0f, ceiling),
          std::clamp(image.rgb[rgb + 1], 0.0f, ceiling),
          std::clamp(image.rgb[rgb + 2], 0.0f, ceiling),
          image.alpha[pixel]};
      if (bytes_per_pixel == 4) {
        dest[0] = static_cast<uint8_t>(ClampByte(channels[0]));
        dest[1] = static_cast<uint8_t>(ClampByte(channels[1]));
        dest[2] = static_cast<uint8_t>(ClampByte(channels[2]));
        dest[3] = static_cast<uint8_t>(ClampByte(channels[3]));
      } else {
        for (int channel = 0; channel < 4; ++channel) {
          const uint16_t half = FloatToHalf(channels[channel]);
          std::memcpy(dest + channel * 2, &half, sizeof(half));
        }
      }
    }
  }
}

}  // namespace

bool VideoQualityEnhancer::SameRequest(
    const RillightCoreEnhancementRequest& request) const {
  return request.interpolation == request_.interpolation &&
         request.anime4k == request_.anime4k &&
         request.super_resolution == request_.super_resolution &&
         request.denoise == request_.denoise &&
         request.sharpen == request_.sharpen &&
         request.accept_leave_native_dolby ==
             request_.accept_leave_native_dolby &&
         request.display_refresh_hz == request_.display_refresh_hz;
}

void VideoQualityEnhancer::Recompute() {
  if (facts_.struct_size == 0) {
    facts_.struct_size = sizeof(facts_);
    facts_.picture_available = 1;
  }
  status_ = ResolveEnhancement(request_, facts_, drop_interpolation_,
                               drop_scale_, drop_spatial_, scale_capacity_);
  if (status_.effective_interpolation != 2) retained_.valid = false;
}

int VideoQualityEnhancer::Configure(
    const RillightCoreEnhancementRequest& request) {
  std::lock_guard lock(mutex_);
  if (!ValidRequest(request)) return -1;
  if (configured_ && SameRequest(request)) return 0;
  request_ = request;
  configured_ = true;
  drop_interpolation_ = 0;
  drop_scale_ = 0;
  drop_spatial_ = 0;
  // Refresh and selection changes do not own scale_capacity_. The current
  // picture's Process does, so a paused display change cannot mark an unfit
  // upscale effective.
  miss_valid_ = false;
  last_note_us_ = -1;
  retained_ = {};
  Recompute();
  return 0;
}

int VideoQualityEnhancer::Retry(const RillightCoreEnhancementRequest& request) {
  std::lock_guard lock(mutex_);
  if (!ValidRequest(request)) return -1;
  request_ = request;
  configured_ = true;
  drop_interpolation_ = 0;
  drop_scale_ = 0;
  drop_spatial_ = 0;
  miss_valid_ = false;
  last_note_us_ = -1;
  retained_ = {};
  Recompute();
  return 0;
}

void VideoQualityEnhancer::ResetSession() {
  std::lock_guard lock(mutex_);
  drop_interpolation_ = 0;
  drop_scale_ = 0;
  drop_spatial_ = 0;
  scale_capacity_ = 0;
  miss_valid_ = false;
  last_note_us_ = -1;
  retained_ = {};
  facts_ = {};
  facts_.struct_size = sizeof(facts_);
  facts_.picture_available = 1;
  Recompute();
}

void VideoQualityEnhancer::ResetTemporal() {
  std::lock_guard lock(mutex_);
  retained_ = {};
  miss_valid_ = false;
}

void VideoQualityEnhancer::UpdatePlaybackFacts(int native_dolby,
                                               double source_frame_rate) {
  std::lock_guard lock(mutex_);
  facts_.struct_size = sizeof(facts_);
  facts_.native_dolby = native_dolby ? 1 : 0;
  facts_.source_frame_rate = SanitizedRate(source_frame_rate);
  if (facts_.picture_available != 0 && facts_.picture_available != 1)
    facts_.picture_available = 1;
  Recompute();
}

void VideoQualityEnhancer::SetPictureAvailable(int available) {
  std::lock_guard lock(mutex_);
  facts_.struct_size = sizeof(facts_);
  const int picture = available ? 1 : 0;
  if (facts_.picture_available == picture && configured_) return;
  facts_.picture_available = picture;
  Recompute();
}

void VideoQualityEnhancer::ApplyLoad(int drop_interpolation, int drop_scale,
                                     int drop_spatial) {
  std::lock_guard lock(mutex_);
  drop_interpolation_ = drop_interpolation ? 1 : 0;
  drop_scale_ = drop_scale ? 1 : 0;
  drop_spatial_ = drop_spatial ? 1 : 0;
  Recompute();
}

int VideoQualityEnhancer::NoteDeadline(int met, int64_t monotonic_us) {
  std::lock_guard lock(mutex_);
  if ((met != 0 && met != 1) || monotonic_us < 0) return -1;
  if (last_note_us_ >= 0 && monotonic_us < last_note_us_) return 0;
  last_note_us_ = monotonic_us;
  if (met) {
    miss_valid_ = false;
    return 0;
  }
  if (!miss_valid_) {
    miss_valid_ = true;
    miss_origin_us_ = monotonic_us;
    return 0;
  }
  if (monotonic_us - miss_origin_us_ < 1000000) return 0;
  if (status_.effective_interpolation == 2) drop_interpolation_ = 1;
  else if (status_.effective_anime4k != 0 ||
           status_.effective_super_resolution != 0)
    drop_scale_ = 1;
  else if (status_.effective_denoise != 0 || status_.effective_sharpen != 0)
    drop_spatial_ = 1;
  else
    return 0;
  miss_origin_us_ = monotonic_us;
  Recompute();
  return 0;
}

RillightCoreEnhancementStatus VideoQualityEnhancer::Status() const {
  std::lock_guard lock(mutex_);
  return status_;
}

bool VideoQualityEnhancer::PictureWork(
    int drop_interpolation, int drop_scale, int drop_spatial,
    int scale_capacity) const {
  RillightCoreEnhancementFacts facts = facts_;
  facts.struct_size = sizeof(facts);
  facts.picture_available = 1;
  const RillightCoreEnhancementStatus status = ResolveEnhancement(
      request_, facts, drop_interpolation, drop_scale, drop_spatial,
      scale_capacity);
  return status.effective_interpolation == 2 || status.effective_anime4k != 0 ||
         status.effective_super_resolution != 0 || status.effective_denoise != 0 ||
         status.effective_sharpen != 0;
}

bool VideoQualityEnhancer::NeedsReconstructedPicture() const {
  std::lock_guard lock(mutex_);
  return PictureWork(drop_interpolation_, drop_scale_, drop_spatial_,
                     scale_capacity_);
}

bool VideoQualityEnhancer::RequestsPicture() const {
  std::lock_guard lock(mutex_);
  return PictureWork(0, 0, 0, 0);
}

VideoQualityEnhancer::Image VideoQualityEnhancer::Decode(
    const uint8_t* src, int width, int height, int stride,
    int bytes_per_pixel) const {
  Image image;
  image.width = width;
  image.height = height;
  image.rgb.assign(static_cast<size_t>(width * height * 3), 0.0f);
  image.alpha.assign(static_cast<size_t>(width * height), 1.0f);
  image.valid = true;
  for (int y = 0; y < height; ++y) {
    const uint8_t* row = src + static_cast<ptrdiff_t>(y) * stride;
    for (int x = 0; x < width; ++x) {
      const uint8_t* pixel = row + static_cast<ptrdiff_t>(x) * bytes_per_pixel;
      const size_t index = static_cast<size_t>(y * width + x);
      if (bytes_per_pixel == 4) {
        image.rgb[index * 3] = pixel[0] / 255.0f;
        image.rgb[index * 3 + 1] = pixel[1] / 255.0f;
        image.rgb[index * 3 + 2] = pixel[2] / 255.0f;
        image.alpha[index] = pixel[3] / 255.0f;
      } else {
        for (int channel = 0; channel < 3; ++channel) {
          uint16_t half = 0;
          std::memcpy(&half, pixel + channel * 2, sizeof(half));
          image.rgb[index * 3 + static_cast<size_t>(channel)] = HalfToFloat(half);
        }
        uint16_t alpha = 0;
        std::memcpy(&alpha, pixel + 6, sizeof(alpha));
        image.alpha[index] = HalfToFloat(alpha);
      }
    }
  }
  return image;
}

VideoQualityEnhancer::Image VideoQualityEnhancer::Filter(
    Image image, bool allow_scale, float ceiling) const {
  if (status_.effective_denoise > 0)
    Denoise(&image, status_.effective_denoise);
  if (status_.effective_sharpen > 0)
    Sharpen(&image, status_.effective_sharpen, ceiling);
  if (allow_scale && status_.effective_anime4k > 0) {
    if (!ApplyAnime4k(&image.rgb, &image.alpha, &image.width, &image.height,
                      status_.effective_anime4k, ceiling))
      return image;
  } else if (allow_scale && status_.effective_super_resolution == 2) {
    if (!ApplySuperResolution(&image.rgb, &image.alpha, &image.width,
                              &image.height, ceiling))
      return image;
  }
  return image;
}

bool VideoQualityEnhancer::HardCut(const Image& prior, const Image& current) {
  if (!prior.valid || prior.width != current.width ||
      prior.height != current.height || prior.rgb.size() != current.rgb.size())
    return true;
  double sum = 0;
  const int count = current.width * current.height;
  for (int i = 0; i < count; ++i) {
    const size_t index = static_cast<size_t>(i * 3);
    sum += std::fabs(static_cast<double>(
        Luma(current.rgb[index], current.rgb[index + 1], current.rgb[index + 2]) -
        Luma(prior.rgb[index], prior.rgb[index + 1], prior.rgb[index + 2])));
  }
  return sum / static_cast<double>(count) > kHardCut;
}

bool VideoQualityEnhancer::Process(
    const uint8_t* src, int width, int height, int stride, int bytes_per_pixel,
    int64_t pts_us, uint64_t timeline, const uint8_t* previous,
    int previous_stride, size_t max_bytes, QualityProcessResult* result) {
  if (!result || !src || width <= 0 || height <= 0 || width > 8192 ||
      height > 8192 || (bytes_per_pixel != 4 && bytes_per_pixel != 8) ||
      stride < width * bytes_per_pixel)
    return false;
  std::lock_guard lock(mutex_);
  result->changed = false;
  result->has_midpoint = false;
  result->current.clear();
  result->midpoint.clear();
  // The previous effective tier is already off while the latch is set, so
  // the request decides whether this picture can hold a 2x upscale.
  const bool wants_scale =
      request_.anime4k != 0 || request_.super_resolution != 0;
  const uint64_t scaled_bytes = static_cast<uint64_t>(width) *
                                static_cast<uint64_t>(height) *
                                static_cast<uint64_t>(bytes_per_pixel) * 4u;
  const bool fits = !wants_scale ||
                    (width <= 4096 && height <= 4096 && scaled_bytes <= max_bytes);
  scale_capacity_ = wants_scale && !fits ? 1 : 0;
  Recompute();
  const bool spatial = status_.effective_denoise > 0 ||
                       status_.effective_sharpen > 0 ||
                       status_.effective_anime4k > 0 ||
                       status_.effective_super_resolution != 0;
  const bool interp = status_.effective_interpolation == 2;
  if (!spatial && !interp) {
    retained_.valid = false;
    result->width = width;
    result->height = height;
    result->stride = width * bytes_per_pixel;
    return true;
  }
  const float ceiling = bytes_per_pixel == 4 ? 1.0f : 8.0f;
  Image current = Decode(src, width, height, stride, bytes_per_pixel);
  current = Filter(std::move(current), scale_capacity_ == 0, ceiling);
  current.pts_us = pts_us;
  current.timeline = timeline;
  Image decoded_prior;
  const Image* previous_image = nullptr;
  if (interp && previous && previous_stride >= width * bytes_per_pixel) {
    decoded_prior = Decode(previous, width, height, previous_stride, bytes_per_pixel);
    decoded_prior = Filter(std::move(decoded_prior), scale_capacity_ == 0, ceiling);
    decoded_prior.timeline = timeline;
    if (decoded_prior.width == current.width && decoded_prior.height == current.height)
      previous_image = &decoded_prior;
  } else if (interp && retained_.valid && retained_.timeline == timeline &&
             retained_.width == current.width &&
             retained_.height == current.height &&
             (retained_.pts_us < 0 || pts_us < 0 || pts_us > retained_.pts_us)) {
    previous_image = &retained_;
  }
  if (spatial) {
    Encode(current, bytes_per_pixel, ceiling, &result->current, &result->stride);
    result->width = current.width;
    result->height = current.height;
    result->changed = true;
  } else {
    result->width = width;
    result->height = height;
    result->stride = width * bytes_per_pixel;
  }
  if (interp && previous_image && !HardCut(*previous_image, current)) {
    const Image& prior = *previous_image;
    Image mid;
    mid.width = current.width;
    mid.height = current.height;
    if (ApplyRife(prior.rgb, current.rgb, current.width, current.height, ceiling,
                  &mid.rgb)) {
      mid.alpha.resize(current.alpha.size());
      for (size_t index = 0; index < mid.alpha.size(); ++index)
        mid.alpha[index] = 0.5f * (prior.alpha[index] + current.alpha[index]);
      Encode(mid, bytes_per_pixel, ceiling, &result->midpoint, &result->mid_stride);
      result->mid_width = mid.width;
      result->mid_height = mid.height;
      result->mid_pts_us = prior.pts_us >= 0 && pts_us >= 0
                               ? prior.pts_us + (pts_us - prior.pts_us) / 2
                               : pts_us;
      result->has_midpoint = true;
    }
  }
  if (interp) retained_ = std::move(current);
  else retained_ = {};
  return true;
}

RillightCoreEnhancementStatus ResolveEnhancement(
    const RillightCoreEnhancementRequest& request,
    const RillightCoreEnhancementFacts& facts, int drop_interpolation,
    int drop_scale, int drop_spatial, int scale_capacity) {
  RillightCoreEnhancementStatus status{};
  status.struct_size = sizeof(status);
  status.requested_interpolation = request.interpolation;
  status.requested_anime4k = request.anime4k;
  status.requested_super_resolution = request.super_resolution;
  status.requested_denoise = request.denoise;
  status.requested_sharpen = request.sharpen;
  const double source = SanitizedRate(facts.source_frame_rate);
  status.source_frame_rate = source;
  const bool dolby = facts.native_dolby == 1 &&
                     request.accept_leave_native_dolby == 0;
  const bool any = request.interpolation != 0 || request.anime4k != 0 ||
                   request.super_resolution != 0 || request.denoise != 0 ||
                   request.sharpen != 0;
  status.left_native_dolby =
      facts.native_dolby == 1 && request.accept_leave_native_dolby == 1 && any
          ? 1
          : 0;
  const bool no_picture = facts.picture_available == 0;
  // 0 is unknown. Double interpolation stays inactive until a positive
  // refresh can show twice the source rate.
  const bool refresh_blocks =
      request.interpolation == 2 &&
      (request.display_refresh_hz <= 0 ||
       (source > 0.0 &&
        source * 2.0 > static_cast<double>(request.display_refresh_hz) + 0.05));
  auto reason = [&](bool requested, bool model, bool refresh, bool overload,
                    bool active) {
    if (!requested) return RILLIGHT_CORE_ENHANCE_REASON_OFF;
    if (dolby) return RILLIGHT_CORE_ENHANCE_REASON_NATIVE_DOLBY;
    if (model) return RILLIGHT_CORE_ENHANCE_REASON_MODEL_UNAVAILABLE;
    if (refresh) return RILLIGHT_CORE_ENHANCE_REASON_REFRESH_CAP;
    if (overload) return RILLIGHT_CORE_ENHANCE_REASON_OVERLOAD;
    if (no_picture) return RILLIGHT_CORE_ENHANCE_REASON_NO_PICTURE;
    if (scale_capacity && active == false &&
        request.anime4k != 0 && !drop_scale)
      return RILLIGHT_CORE_ENHANCE_REASON_CAPACITY;
    return active ? RILLIGHT_CORE_ENHANCE_REASON_ACTIVE
                  : RILLIGHT_CORE_ENHANCE_REASON_OFF;
  };
  // Ordinary playback must not initialize and hash unused model assets.
  const bool rife_ready = request.interpolation == 2 && RifeReady();
  const bool anime_ready = request.anime4k != 0 && Anime4kShadersReady();
  const bool sr_ready = request.super_resolution == 2 && SuperResolutionReady();
  const bool interp_on = request.interpolation == 2 && rife_ready && !dolby &&
                         !refresh_blocks && drop_interpolation == 0 && !no_picture;
  const bool anime_on = request.anime4k != 0 && anime_ready && !dolby &&
                        drop_scale == 0 && !no_picture && scale_capacity == 0;
  const bool sr_on = request.super_resolution == 2 && sr_ready &&
                     request.anime4k == 0 && !dolby && drop_scale == 0 &&
                     !no_picture && scale_capacity == 0;
  const bool denoise_on = request.denoise != 0 && !dolby && drop_spatial == 0 &&
                          !no_picture;
  const bool sharpen_on = request.sharpen != 0 && !dolby && drop_spatial == 0 &&
                          !no_picture;
  status.effective_interpolation = interp_on ? 2 : 0;
  status.effective_anime4k = anime_on ? request.anime4k : 0;
  status.effective_super_resolution = sr_on ? 2 : 0;
  status.effective_denoise = denoise_on ? request.denoise : 0;
  status.effective_sharpen = sharpen_on ? request.sharpen : 0;
  status.reason_interpolation =
      reason(request.interpolation == 2, !rife_ready, refresh_blocks,
             drop_interpolation != 0, interp_on);
  status.reason_anime4k = reason(request.anime4k != 0, !anime_ready, false,
                                 drop_scale != 0, anime_on);
  if (request.anime4k != 0 && anime_ready && !dolby && !no_picture &&
      drop_scale == 0 && scale_capacity != 0)
    status.reason_anime4k = RILLIGHT_CORE_ENHANCE_REASON_CAPACITY;
  status.reason_super_resolution =
      reason(request.super_resolution == 2, !sr_ready, false, drop_scale != 0,
             sr_on);
  if (request.super_resolution == 2 && request.anime4k == 0 && sr_ready &&
      !dolby && !no_picture && drop_scale == 0 && scale_capacity != 0)
    status.reason_super_resolution = RILLIGHT_CORE_ENHANCE_REASON_CAPACITY;
  status.reason_denoise =
      reason(request.denoise != 0, false, false, drop_spatial != 0, denoise_on);
  status.reason_sharpen =
      reason(request.sharpen != 0, false, false, drop_spatial != 0, sharpen_on);
  status.interpolation_backend = interp_on ? RILLIGHT_CORE_INTERP_BACKEND_RIFE
                                            : RILLIGHT_CORE_INTERP_BACKEND_NONE;
  status.anime4k_backend = anime_on ? RILLIGHT_CORE_ANIME4K_BACKEND_GLSL
                                    : RILLIGHT_CORE_ANIME4K_BACKEND_NONE;
  status.super_resolution_backend = sr_on ? RILLIGHT_CORE_SR_BACKEND_REALESRGAN
                                          : RILLIGHT_CORE_SR_BACKEND_NONE;
  status.output_frame_rate = interp_on ? source * 2.0 : source;
  return status;
}

}  // namespace rillight

namespace {

bool ValidFacts(const RillightCoreEnhancementFacts& facts) {
  if (facts.struct_size != sizeof(facts)) return false;
  if (facts.native_dolby != 0 && facts.native_dolby != 1) return false;
  if (facts.picture_available != 0 && facts.picture_available != 1) return false;
  if (!std::isfinite(facts.source_frame_rate) || facts.source_frame_rate < 0.0 ||
      facts.source_frame_rate > 240.0)
    return false;
  return true;
}

bool ValidLoad(const RillightCoreEnhancementLoad& load) {
  if (load.struct_size != sizeof(load)) return false;
  if ((load.drop_interpolation != 0 && load.drop_interpolation != 1) ||
      (load.drop_scale != 0 && load.drop_scale != 1) ||
      (load.drop_spatial != 0 && load.drop_spatial != 1))
    return false;
  return true;
}

}  // namespace

namespace {

RillightCoreEnhancementRequest probe_request(int interpolation, int anime4k,
                                             int super_resolution,
                                             int refresh_hz) {
  RillightCoreEnhancementRequest request{};
  request.struct_size = sizeof(request);
  request.interpolation = interpolation;
  request.anime4k = anime4k;
  request.super_resolution = super_resolution;
  request.display_refresh_hz = refresh_hz;
  return request;
}

bool probe_process(rillight::VideoQualityEnhancer* enhancer, int width,
                   int height, uint8_t value, size_t max_bytes,
                   rillight::QualityProcessResult* result) {
  std::vector<uint8_t> pixels(static_cast<size_t>(width * height * 4), value);
  return enhancer->Process(pixels.data(), width, height, width * 4, 4, 0, 1,
                           nullptr, 0, max_bytes, result);
}

}  // namespace

extern "C" {

// 0 when a refresh-only configure keeps an unfit upscale inactive and
// recomputes interpolation. Any other value is the failing step.
RILLIGHT_CORE_API int rillight_enhancement_refresh_capacity_probe(void) {
  rillight::VideoQualityEnhancer enhancer;
  auto request = probe_request(2, 2, 0, 120);
  if (enhancer.Configure(request) != 0) return 1;
  enhancer.UpdatePlaybackFacts(0, 30.0);
  constexpr int kWidth = 48;
  constexpr int kHeight = 48;
  const size_t too_small =
      static_cast<size_t>(kWidth) * kHeight * 4u * 4u - 1u;
  rillight::QualityProcessResult processed;
  if (!probe_process(&enhancer, kWidth, kHeight, 0, too_small, &processed))
    return 2;
  auto status = enhancer.Status();
  if (status.effective_anime4k != 0 ||
      status.reason_anime4k != RILLIGHT_CORE_ENHANCE_REASON_CAPACITY)
    return 3;
  if (status.effective_interpolation != 2 || processed.width != kWidth)
    return 4;
  if (!probe_process(&enhancer, kWidth, kHeight, 255, too_small, &processed))
    return 5;
  status = enhancer.Status();
  if (status.effective_anime4k != 0 ||
      status.reason_anime4k != RILLIGHT_CORE_ENHANCE_REASON_CAPACITY ||
      processed.width != kWidth)
    return 6;

  request.display_refresh_hz = 50;
  if (enhancer.Configure(request) != 0) return 7;
  status = enhancer.Status();
  if (status.effective_interpolation != 0 ||
      status.reason_interpolation != RILLIGHT_CORE_ENHANCE_REASON_REFRESH_CAP ||
      status.output_frame_rate != 30.0)
    return 8;
  if (status.effective_anime4k != 0 ||
      status.reason_anime4k != RILLIGHT_CORE_ENHANCE_REASON_CAPACITY)
    return 9;

  request.display_refresh_hz = 0;
  if (enhancer.Configure(request) != 0) return 10;
  status = enhancer.Status();
  if (status.effective_interpolation != 0 ||
      status.reason_interpolation != RILLIGHT_CORE_ENHANCE_REASON_REFRESH_CAP ||
      status.effective_anime4k != 0)
    return 11;

  request.display_refresh_hz = 120;
  if (enhancer.Configure(request) != 0) return 12;
  status = enhancer.Status();
  if (status.effective_interpolation != 2 || status.output_frame_rate != 60.0 ||
      status.effective_anime4k != 0 ||
      status.reason_anime4k != RILLIGHT_CORE_ENHANCE_REASON_CAPACITY)
    return 13;

  request = probe_request(0, 0, 2, 120);
  if (enhancer.Configure(request) != 0) return 14;
  status = enhancer.Status();
  if (status.effective_super_resolution != 0 ||
      status.reason_super_resolution != RILLIGHT_CORE_ENHANCE_REASON_CAPACITY)
    return 15;

  if (!probe_process(&enhancer, 8, 8, 90, too_small, &processed)) return 16;
  status = enhancer.Status();
  if (status.effective_super_resolution != 2 || processed.width != 16)
    return 17;

  request = probe_request(2, 2, 0, 120);
  if (enhancer.Configure(request) != 0) return 18;
  if (!probe_process(&enhancer, kWidth, kHeight, 20, too_small, &processed))
    return 19;
  if (enhancer.NoteDeadline(0, 0) != 0 ||
      enhancer.NoteDeadline(0, 1000000) != 0)
    return 20;
  status = enhancer.Status();
  if (status.effective_interpolation != 0 || status.effective_anime4k != 0)
    return 21;
  if (enhancer.Configure(request) != 0) return 22;
  status = enhancer.Status();
  if (status.effective_interpolation != 0 ||
      status.reason_anime4k != RILLIGHT_CORE_ENHANCE_REASON_CAPACITY)
    return 23;
  if (enhancer.Retry(request) != 0) return 24;
  status = enhancer.Status();
  if (status.effective_interpolation != 2 || status.effective_anime4k != 0 ||
      status.reason_anime4k != RILLIGHT_CORE_ENHANCE_REASON_CAPACITY)
    return 25;

  std::vector<uint8_t> wide(static_cast<size_t>(4097 * 4), 30);
  if (!enhancer.Process(wide.data(), 4097, 1, 4097 * 4, 4, 0, 1, nullptr, 0,
                        1024u * 1024u, &processed))
    return 26;
  request.display_refresh_hz = 30;
  if (enhancer.Configure(request) != 0) return 27;
  status = enhancer.Status();
  if (status.effective_anime4k != 0 ||
      status.reason_anime4k != RILLIGHT_CORE_ENHANCE_REASON_CAPACITY ||
      status.effective_interpolation != 0)
    return 28;
  return 0;
}

int rillight_enhancement_model_ready(int kind) {
  if (kind == 0) return rillight::RifeReady() ? 1 : 0;
  if (kind == 1) return rillight::Anime4kShadersReady() ? 1 : 0;
  if (kind == 2) return rillight::SuperResolutionReady() ? 1 : 0;
  return 0;
}

int rillight_enhancement_resolve(const RillightCoreEnhancementRequest* request,
                                 const RillightCoreEnhancementFacts* facts,
                                 const RillightCoreEnhancementLoad* load,
                                 RillightCoreEnhancementStatus* status) {
  if (!request || !facts || !load || !status ||
      status->struct_size < sizeof(*status))
    return -1;
  if (!rillight::ValidRequest(*request) || !ValidFacts(*facts) ||
      !ValidLoad(*load))
    return -1;
  *status = rillight::ResolveEnhancement(
      *request, *facts, load->drop_interpolation, load->drop_scale,
      load->drop_spatial, 0);
  return 0;
}

int rillight_enhancement_process_rgba(
    const RillightCoreEnhancementRequest* request,
    const RillightCoreEnhancementFacts* facts,
    const RillightCoreEnhancementLoad* load, const uint8_t* src, int width,
    int height, int stride, const uint8_t* previous, int previous_stride,
    uint8_t* dst, int dst_capacity, int* out_width, int* out_height,
    uint8_t* midpoint, int midpoint_capacity, int* midpoint_bytes) {
  if (!request || !facts || !out_width || !out_height || !midpoint_bytes)
    return -1;
  RillightCoreEnhancementLoad none{};
  none.struct_size = sizeof(none);
  const RillightCoreEnhancementLoad* applied = load ? load : &none;
  if (!ValidFacts(*facts) || !ValidLoad(*applied)) return -1;
  rillight::VideoQualityEnhancer enhancer;
  if (enhancer.Configure(*request) != 0) return -1;
  enhancer.UpdatePlaybackFacts(facts->native_dolby, facts->source_frame_rate);
  enhancer.SetPictureAvailable(facts->picture_available);
  enhancer.ApplyLoad(applied->drop_interpolation, applied->drop_scale,
                     applied->drop_spatial);
  rillight::QualityProcessResult processed;
  if (!enhancer.Process(src, width, height, stride, 4, 0, 1, previous,
                        previous_stride, 128u * 1024u * 1024u, &processed))
    return -1;
  *out_width = processed.width;
  *out_height = processed.height;
  *midpoint_bytes = 0;
  if (processed.changed) {
    if (!dst || dst_capacity < static_cast<int>(processed.current.size()))
      return -1;
    std::memcpy(dst, processed.current.data(), processed.current.size());
  } else if (dst && src && dst != src && dst_capacity >= height * width * 4) {
    for (int y = 0; y < height; ++y) {
      std::memcpy(dst + static_cast<ptrdiff_t>(y) * width * 4,
                  src + static_cast<ptrdiff_t>(y) * stride,
                  static_cast<size_t>(width * 4));
    }
  }
  if (processed.has_midpoint) {
    if (!midpoint ||
        midpoint_capacity < static_cast<int>(processed.midpoint.size()))
      return -1;
    std::memcpy(midpoint, processed.midpoint.data(), processed.midpoint.size());
    *midpoint_bytes = static_cast<int>(processed.midpoint.size());
  }
  return 0;
}

}  // extern "C"
