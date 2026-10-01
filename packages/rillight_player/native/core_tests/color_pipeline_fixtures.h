#pragma once

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstring>
#include <vector>

extern "C" {
#include <libavutil/dovi_meta.h>
#include <libavutil/frame.h>
#include <libavutil/mem.h>
#include <libavutil/pixdesc.h>
}

namespace {
inline AVFrame* Picture(AVPixelFormat format, uint16_t level) {
  AVFrame* frame = av_frame_alloc();
  assert(frame);
  frame->width = 64;
  frame->height = 48;
  frame->format = format;
  frame->color_trc = AVCOL_TRC_SMPTE2084;
  frame->color_primaries = AVCOL_PRI_BT2020;
  frame->colorspace = AVCOL_SPC_BT2020_NCL;
  frame->color_range = AVCOL_RANGE_MPEG;
  assert(av_frame_get_buffer(frame, 32) == 0);
  const int depth = av_pix_fmt_desc_get(format)->comp[0].depth;
  const bool packed = format == AV_PIX_FMT_P010LE || format == AV_PIX_FMT_P012LE ||
                      format == AV_PIX_FMT_P016LE;
  const uint16_t neutral = static_cast<uint16_t>(1u << (depth - 1));
  for (int y = 0; y < frame->height; ++y) {
    auto* row = reinterpret_cast<uint16_t*>(frame->data[0] + y * frame->linesize[0]);
    std::fill_n(row, frame->width, packed ? level << (16 - depth) : level);
  }
  for (int y = 0; y < frame->height / 2; ++y) {
    auto* row = reinterpret_cast<uint16_t*>(frame->data[1] + y * frame->linesize[1]);
    if (packed) {
      std::fill_n(row, frame->width, neutral << (16 - depth));
    } else {
      std::fill_n(row, frame->width / 2, neutral);
      auto* v = reinterpret_cast<uint16_t*>(frame->data[2] + y * frame->linesize[2]);
      std::fill_n(v, frame->width / 2, neutral);
    }
  }
  return frame;
}

inline AVDOVIMetadata* Metadata(AVFrame* frame) {
  size_t size = 0;
  auto* original = av_dovi_metadata_alloc(&size);
  assert(original);
  auto* side = av_frame_new_side_data(frame, AV_FRAME_DATA_DOVI_METADATA, size);
  assert(side);
  std::memcpy(side->data, original, size);
  av_free(original);
  auto* metadata = reinterpret_cast<AVDOVIMetadata*>(side->data);
  auto* header = av_dovi_get_header(metadata);
  header->disable_residual_flag = 1;
  header->bl_bit_depth = av_pix_fmt_desc_get(static_cast<AVPixelFormat>(frame->format))->comp[0].depth;
  header->coef_log2_denom = 0;
  auto* color = av_dovi_get_color(metadata);
  for (int i = 0; i < 9; ++i) {
    const AVRational element{i % 4 == 0 ? 1 : 0, 1};
    color->ycc_to_rgb_matrix[i] = element;
    color->rgb_to_lms_matrix[i] = element;
  }
  for (auto& offset : color->ycc_to_rgb_offset) offset = AVRational{0, 1};
  auto* mapping = av_dovi_get_mapping(metadata);
  for (auto& curve : mapping->curves) {
    curve.num_pivots = 2;
    curve.pivots[0] = 0;
    curve.pivots[1] = static_cast<uint16_t>((1u << header->bl_bit_depth) - 1);
    curve.mapping_idc[0] = AV_DOVI_MAPPING_POLYNOMIAL;
    curve.poly_order[0] = 1;
    curve.poly_coef[0][1] = 1;
  }
  return metadata;
}

inline void Gray(const std::vector<uint8_t>& rgba, int minimum, int maximum) {
  for (size_t i = 0; i < rgba.size(); i += 4) {
    assert(rgba[i] >= minimum && rgba[i] <= maximum);
    assert(std::abs(static_cast<int>(rgba[i]) - rgba[i + 1]) <= 2);
    assert(std::abs(static_cast<int>(rgba[i]) - rgba[i + 2]) <= 2);
    assert(rgba[i + 3] == 255);
  }
}

inline int ReferenceGray(int code) {
  const double normalized = code / 1023.0;
  const double p = std::pow(normalized, 1.0 / 78.84375);
  const double nits = 10000 * std::pow(std::max(p - .8359375, 0.0) /
      (18.8515625 - 18.6875 * p), 1.0 / .1593017578125);
  const double linear = std::clamp(nits * (1 + 203.0 / 1000) / (203 + nits), 0.0, 1.0);
  const double srgb = linear <= .0031308 ? 12.92 * linear :
      1.055 * std::pow(linear, 1.0 / 2.4) - .055;
  return static_cast<int>(std::lround(255 * srgb));
}
}  // namespace
