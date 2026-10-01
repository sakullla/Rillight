#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

extern "C" {
#include <libavutil/dovi_meta.h>
#include <libavutil/frame.h>
}

// Parsed per-frame RPU constants shared by all owned rendering backends.
namespace rillight_color {
struct Vec4 { float x = 0, y = 0, z = 0, w = 0; };
struct Piece { Vec4 polynomial; Vec4 mmr[6]; };
struct Curve { Vec4 bounds; Vec4 pivots[3]; Piece pieces[8]; };
struct Constants {
  Vec4 output;  // output width/height, normalization factor, transfer mode
  Vec4 visible; // visible / allocated source size, BT.2020 flag, source peak
  Vec4 range;   // luma offset/scale, chroma offset/scale
  Vec4 offset;
  Vec4 nonlinear[3];
  Vec4 linear[3];
  Curve curves[3];
};
static_assert(sizeof(Constants) % 16 == 0);

inline bool DoviConstants(const AVFrame* frame, Constants* constants) {
  const auto* side = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA);
  if (!side || !side->data || side->size < sizeof(AVDOVIMetadata)) return false;
  const auto* metadata = reinterpret_cast<const AVDOVIMetadata*>(side->data);
  const auto contains = [&](size_t offset, size_t bytes) {
    return offset <= side->size && bytes <= side->size - offset;
  };
  if (!contains(metadata->header_offset, sizeof(AVDOVIRpuDataHeader)) ||
      !contains(metadata->mapping_offset, sizeof(AVDOVIDataMapping)) ||
      !contains(metadata->color_offset, sizeof(AVDOVIColorMetadata))) return false;
  const auto* header = av_dovi_get_header(metadata);
  const auto* mapping = av_dovi_get_mapping(metadata);
  const auto* color = av_dovi_get_color(metadata);
  if (!header->disable_residual_flag || header->bl_bit_depth < 8 ||
      header->bl_bit_depth > 16 || header->coef_log2_denom > 63 ||
      color->source_min_pq > 4095 || color->source_max_pq > 4095 ||
      (color->source_max_pq && color->source_min_pq > color->source_max_pq)) return false;
  const auto valid_rational = [](AVRational value) {
    return value.den > 0 && std::isfinite(av_q2d(value));
  };
  for (const auto& value : color->ycc_to_rgb_offset)
    if (!valid_rational(value)) return false;
  for (const auto& value : color->ycc_to_rgb_matrix)
    if (!valid_rational(value)) return false;
  for (const auto& value : color->rgb_to_lms_matrix)
    if (!valid_rational(value)) return false;
  constants->output.w = 3;
  constants->visible.z = 1;
  constants->offset = {static_cast<float>(av_q2d(color->ycc_to_rgb_offset[0])),
                        static_cast<float>(av_q2d(color->ycc_to_rgb_offset[1])),
                        static_cast<float>(av_q2d(color->ycc_to_rgb_offset[2])), 0};
  const double lms_to_rgb[3][3] = {
      {3.06441879, -2.16597676, .10155818},
      {-.65612108, 1.78554118, -.12943749},
      {.01736321, -.04725154, 1.03004253}};
  for (int row = 0; row < 3; ++row) {
    float nonlinear[3];
    float linear[3]{};
    for (int column = 0; column < 3; ++column) {
      nonlinear[column] = static_cast<float>(av_q2d(color->ycc_to_rgb_matrix[3 * row + column]));
      for (int i = 0; i < 3; ++i)
        linear[column] += static_cast<float>(lms_to_rgb[row][i] *
            av_q2d(color->rgb_to_lms_matrix[3 * i + column]));
    }
    constants->nonlinear[row] = {nonlinear[0], nonlinear[1], nonlinear[2], 0};
    constants->linear[row] = {linear[0], linear[1], linear[2], 0};
  }
  const double denominator = std::ldexp(1.0, -header->coef_log2_denom);
  const float maximum = static_cast<float>((1u << header->bl_bit_depth) - 1);
  for (int channel = 0; channel < 3; ++channel) {
    const auto& source = mapping->curves[channel];
    auto& destination = constants->curves[channel];
    if (source.num_pivots == 0) continue;
    if (source.num_pivots < 2 || source.num_pivots > 9) return false;
    destination.bounds = {static_cast<float>(source.num_pivots),
        source.pivots[0] / maximum, source.pivots[source.num_pivots - 1] / maximum, 0};
    for (int i = 0; i < source.num_pivots; ++i) {
      if (source.pivots[i] > maximum) return false;
      if (i && source.pivots[i] < source.pivots[i - 1]) return false;
      auto* values = reinterpret_cast<float*>(&destination.pivots[i / 4]);
      values[i % 4] = source.pivots[i] / maximum;
    }
    for (int i = 0; i < source.num_pivots - 1; ++i) {
      auto& piece = destination.pieces[i];
      if (source.mapping_idc[i] == AV_DOVI_MAPPING_POLYNOMIAL) {
        if (source.poly_order[i] < 1 || source.poly_order[i] > 2) return false;
        piece.polynomial = {static_cast<float>(source.poly_coef[i][0] * denominator),
                             static_cast<float>(source.poly_coef[i][1] * denominator),
                             source.poly_order[i] == 2 ? static_cast<float>(source.poly_coef[i][2] * denominator) : 0, 0};
      } else if (source.mapping_idc[i] == AV_DOVI_MAPPING_MMR) {
        if (source.mmr_order[i] < 1 || source.mmr_order[i] > 3) return false;
        piece.polynomial = {static_cast<float>(source.mmr_constant[i] * denominator), 0, 0,
                             static_cast<float>(source.mmr_order[i])};
        for (int order = 0; order < source.mmr_order[i]; ++order) {
          const auto* weights = source.mmr_coef[i][order];
          piece.mmr[2 * order] = {static_cast<float>(weights[0] * denominator),
                                  static_cast<float>(weights[1] * denominator),
                                  static_cast<float>(weights[2] * denominator), 0};
          piece.mmr[2 * order + 1] = {static_cast<float>(weights[3] * denominator),
                                      static_cast<float>(weights[4] * denominator),
                                      static_cast<float>(weights[5] * denominator),
                                      static_cast<float>(weights[6] * denominator)};
        }
      } else return false;
    }
  }
  if (color->source_max_pq > 0) {
    const double p = std::pow(color->source_max_pq / 4095.0, 1.0 / 78.84375);
    constants->visible.w = static_cast<float>(10000.0 * std::pow(
        std::max(p - .8359375, 0.0) / std::max(18.8515625 - 18.6875 * p, 1e-9),
        1.0 / .1593017578125));
  }
  return true;
}
}  // namespace rillight_color
