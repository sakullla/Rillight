#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace rillight::core {
// The overlay contract is premultiplied sRGB, including on HDR presenters
// (which lift it to their SDR reference white). UHD PGS is authored in the
// video's BT.2020/PQ space, not that overlay space. Normalize its small palette
// once per display set, before alpha premultiplication, rather than per pixel.
inline uint32_t pq_pgs_to_srgb(uint32_t color, bool decoder_uses_bt601) {
  if (!(color >> 24)) return color;
  std::array<double, 3> rgb{
      ((color >> 16) & 255) / 255.0,
      ((color >> 8) & 255) / 255.0, (color & 255) / 255.0};
  // FFmpeg's PGS decoder uses BT.709 above 576 lines, BT.601 otherwise.
  // Undo that matrix before interpreting the palette as BT.2020. Already
  // clipped/quantized decoder colors cannot be recovered exactly.
  const double kr = decoder_uses_bt601 ? .299 : .2126;
  const double kb = decoder_uses_bt601 ? .114 : .0722;
  const double y = kr * rgb[0] + (1 - kr - kb) * rgb[1] + kb * rgb[2];
  const double cb = (rgb[2] - y) / (2 * (1 - kb));
  const double cr = (rgb[0] - y) / (2 * (1 - kr));
  rgb[0] = y + 1.4746 * cr;
  rgb[2] = y + 1.8814 * cb;
  rgb[1] = (y - .2627 * rgb[0] - .0593 * rgb[2]) / .678;
  for (auto& c : rgb) {
    const double p = std::pow(std::clamp(c, 0.0, 1.0), 1 / 78.84375);
    c = 10000 * std::pow(std::max(p - .8359375, 0.0) /
        (18.8515625 - 18.6875 * p), 1 / .1593017578125);
  }
  const auto wide = rgb;
  rgb = {1.660491 * wide[0] - .587641 * wide[1] - .072850 * wide[2],
         -.124550 * wide[0] + 1.132900 * wide[1] - .008349 * wide[2],
         -.018151 * wide[0] - .100579 * wide[1] + 1.118730 * wide[2]};
  // Use the video SDR mapper's curve and reference white. Image subtitles
  // have no mastering metadata of their own: use a stable 1000-nit peak,
  // never scene-dependent video/RPU peaks that would make text pulse.
  const double luma = std::max(.2126 * rgb[0] + .7152 * rgb[1] + .0722 * rgb[2], 0.0);
  const double mapped = luma * (1 + 203.0 / 1000) / (203 + luma);
  for (auto& c : rgb) c *= luma > 1e-6 ? mapped / luma : 0;
  const double neutral = std::clamp(mapped, 0.0, 1.0);
  const double low = std::min({rgb[0], rgb[1], rgb[2]});
  const double high = std::max({rgb[0], rgb[1], rgb[2]});
  double amount = 1;
  if (low < 0) amount = std::min(amount, mapped / std::max(mapped - low, 1e-6));
  if (high > 1) amount = std::min(amount, (1 - neutral) / std::max(high - mapped, 1e-6));
  amount = std::clamp(amount, 0.0, 1.0);
  uint32_t result = color & 0xff000000;
  for (int channel = 0; channel < 3; ++channel) {
    const double linear = std::clamp(neutral + (rgb[channel] - neutral) * amount, 0.0, 1.0);
    const double code = linear <= .0031308 ? linear * 12.92 :
        1.055 * std::pow(linear, 1 / 2.4) - .055;
    result |= static_cast<uint32_t>(std::lround(code * 255)) << (16 - 8 * channel);
  }
  return result;
}
}  // namespace rillight::core
