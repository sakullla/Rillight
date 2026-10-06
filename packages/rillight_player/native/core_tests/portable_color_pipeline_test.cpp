#include "../core/dovi_color_metadata.h"
#include "../core/dovi_enhancement.h"
#include "../core/dovi_profile.h"
#include "../core/portable_color_pipeline.h"
#include "color_pipeline_fixtures.h"

float HalfToFloat(uint16_t half) {
  const uint32_t sign = static_cast<uint32_t>(half & 0x8000u) << 16;
  const uint32_t exponent = (half >> 10) & 0x1fu;
  const uint32_t mantissa = half & 0x3ffu;
  uint32_t bits = 0;
  if (exponent == 0) bits = sign;
  else if (exponent == 31) bits = sign | 0x7f800000u | (mantissa << 13);
  else bits = sign | ((exponent + 112) << 23) | (mantissa << 13);
  float value = 0;
  std::memcpy(&value, &bits, sizeof(value));
  return value;
}

int main() {
  PortableColorPipeline pipeline;
  {
    AVFrame* bright = Picture(AV_PIX_FMT_YUV420P10LE, 940);
    std::vector<uint8_t> mapped(32 * 24 * 4);
    assert(pipeline.Render(bright, 32, 24, false, mapped.data(), 32 * 4));
    std::vector<uint16_t> linear(32 * 24 * 4);
    assert(pipeline.RenderLinearHalf(bright, 32, 24, false, linear.data(), 32 * 8));
    const float peak = HalfToFloat(linear[0]);
    assert(peak > 1.0f);
    assert(mapped[0] == 255 || peak > mapped[0] / 255.0f);
    AVFrame* dark = Picture(AV_PIX_FMT_YUV420P10LE, 64);
    assert(pipeline.RenderLinearHalf(dark, 32, 24, false, linear.data(), 32 * 8));
    assert(HalfToFloat(linear[0]) < peak);
    assert(!pipeline.RenderLinearHalf(dark, 32, 24, false, linear.data(), 32 * 4));
    av_frame_free(&bright);
    av_frame_free(&dark);
  }
  std::vector<uint8_t> pixels(32 * 24 * 4);
  for (const auto format : {AV_PIX_FMT_YUV420P10LE, AV_PIX_FMT_P010LE,
                            AV_PIX_FMT_YUV420P12LE, AV_PIX_FMT_P012LE,
                            AV_PIX_FMT_YUV420P16LE, AV_PIX_FMT_P016LE}) {
    const int depth = av_pix_fmt_desc_get(format)->comp[0].depth;
    AVFrame* hdr = Picture(format, static_cast<uint16_t>(16u << (depth - 8)));
    assert(pipeline.Render(hdr, 32, 24, false, pixels.data(), 32 * 4));
    Gray(pixels, 0, 1);
    av_frame_free(&hdr);
    AVFrame* dovi = Picture(format, static_cast<uint16_t>(1u << (depth - 1)));
    auto* metadata = Metadata(dovi);
    assert(pipeline.Render(dovi, 32, 24, true, pixels.data(), 32 * 4));
    Gray(pixels, 100, 200);
    const auto polynomial = pixels;
    auto* mapping = av_dovi_get_mapping(metadata);
    for (int c = 0; c < 3; ++c) {
      auto& curve = mapping->curves[c];
      curve.mapping_idc[0] = AV_DOVI_MAPPING_MMR;
      curve.mmr_order[0] = 1;
      curve.mmr_coef[0][0][c] = 1;
    }
    assert(pipeline.Render(dovi, 32, 24, true, pixels.data(), 32 * 4));
    assert(pixels == polynomial);
    av_dovi_get_color(metadata)->source_max_pq = 4096;
    assert(!pipeline.Render(dovi, 32, 24, true, pixels.data(), 32 * 4));
    av_frame_free(&dovi);
  }
  for (int code = 0; code <= 1023; code += 17) {
    AVFrame* dovi = Picture(AV_PIX_FMT_YUV420P10LE, static_cast<uint16_t>(code));
    Metadata(dovi);
    for (int plane = 1; plane <= 2; ++plane)
      for (int y = 0; y < dovi->height / 2; ++y)
        std::fill_n(reinterpret_cast<uint16_t*>(dovi->data[plane] + y * dovi->linesize[plane]),
                    dovi->width / 2, static_cast<uint16_t>(code));
    assert(pipeline.Render(dovi, 32, 24, true, pixels.data(), 32 * 4));
    const int reference = ReferenceGray(code);
    Gray(pixels, std::max(0, reference - 2), std::min(255, reference + 2));
    av_frame_free(&dovi);
  }
  AVFrame* invalid = Picture(AV_PIX_FMT_YUV420P10LE, 512);
  assert(!pipeline.Render(invalid, 32, 24, true, pixels.data(), 32 * 4));
  assert(!pipeline.Render(invalid, 32, 24, false, pixels.data(), 1));
  auto* metadata = Metadata(invalid);
  auto* color = av_dovi_get_color(metadata);
  color->ycc_to_rgb_matrix[0].den = 0;
  assert(!pipeline.Render(invalid, 32, 24, true, pixels.data(), 32 * 4));
  color->ycc_to_rgb_matrix[0].den = 1;
  av_dovi_get_header(metadata)->disable_residual_flag = 0;
  assert(!pipeline.Render(invalid, 32, 24, true, pixels.data(), 32 * 4));
  // An HDR10-compatible base can be processed independently of an unsupported
  // FEL RPU, without reducing the input to 8-bit before tone mapping.
  assert(pipeline.Render(invalid, 32, 24, false, pixels.data(), 32 * 4));
  Gray(pixels, 100, 200);
  av_frame_free(&invalid);

  AVFrame* base = Picture(AV_PIX_FMT_YUV420P10LE, 64);
  auto* base_metadata = Metadata(base);
  // av_frame_clone shares the pixel buffers. The playback path copies before
  // writing, so a cloned decoder frame stays on the base sample.
  AVFrame* alias = av_frame_clone(base);
  assert(alias && alias->data[0] == base->data[0]);
  AVFrame* owned = rillight_color::CopyFrameForCompose(base);
  assert(owned && owned->data[0] != base->data[0]);
  AVFrame* layer = Picture(AV_PIX_FMT_YUV420P10LE, 800);
  assert(layer);
  const auto fallback = dovi_frame_decision(7, 6, 1, 1, 1, 0);
  assert(fallback.reconstruction == RILLIGHT_CORE_DOVI_RECON_BASE_FALLBACK);
  assert(fallback.reconstruction != RILLIGHT_CORE_DOVI_RECON_FEL);
  assert(fallback.emit_picture == 1 && fallback.use_rpu == 0);
  assert(rillight_color::ComposeFelResidual(owned, layer));
  assert(reinterpret_cast<uint16_t*>(base->data[0])[0] == 64);
  assert(reinterpret_cast<uint16_t*>(alias->data[0])[0] == 64);
  assert(reinterpret_cast<uint16_t*>(owned->data[0])[0] == 352);
  auto* owned_metadata = reinterpret_cast<AVDOVIMetadata*>(
      av_frame_get_side_data(owned, AV_FRAME_DATA_DOVI_METADATA)->data);
  av_dovi_get_header(owned_metadata)->disable_residual_flag = 0;
  assert(av_dovi_get_header(base_metadata)->disable_residual_flag == 1);
  const auto completed = dovi_frame_decision(7, 6, 1, 1, 1, 1);
  assert(completed.reconstruction == RILLIGHT_CORE_DOVI_RECON_FEL);
  assert(completed.use_rpu == 1);
  av_dovi_get_header(owned_metadata)->disable_residual_flag = 1;
  std::vector<uint8_t> base_pixels(32 * 24 * 4);
  std::vector<uint8_t> fel_pixels(32 * 24 * 4);
  assert(pipeline.Render(base, 32, 24, true, base_pixels.data(), 32 * 4));
  assert(pipeline.Render(owned, 32, 24, true, fel_pixels.data(), 32 * 4));
  assert(base_pixels != fel_pixels);
  AVFrame* neutral = Picture(AV_PIX_FMT_YUV420P10LE, 512);
  AVFrame* unchanged = rillight_color::CopyFrameForCompose(base);
  assert(neutral && unchanged);
  assert(!rillight_color::ComposeFelResidual(unchanged, neutral));
  assert(reinterpret_cast<uint16_t*>(unchanged->data[0])[0] == 64);
  assert(dovi_frame_decision(7, 6, 1, 1, 1, 0).reconstruction != RILLIGHT_CORE_DOVI_RECON_FEL);
  AVFrame* shaped = rillight_color::CopyFrameForCompose(base);
  assert(shaped);
  auto* shaped_metadata = reinterpret_cast<AVDOVIMetadata*>(
      av_frame_get_side_data(shaped, AV_FRAME_DATA_DOVI_METADATA)->data);
  auto* shaped_header = av_dovi_get_header(shaped_metadata);
  shaped_header->el_bit_depth = 10;
  shaped_header->coef_log2_denom = 10;
  auto* shaped_mapping = av_dovi_get_mapping(shaped_metadata);
  shaped_mapping->nlq_method_idc = AV_DOVI_NLQ_LINEAR_DZ;
  for (int channel = 0; channel < 3; ++channel) {
    shaped_mapping->nlq[channel].nlq_offset = 0;
    shaped_mapping->nlq[channel].linear_deadzone_slope = 1024;
    shaped_mapping->nlq[channel].linear_deadzone_threshold = 0;
    shaped_mapping->nlq[channel].vdr_in_max = 1024;
  }
  assert(rillight_color::ComposeFelResidual(shaped, layer));
  assert(reinterpret_cast<uint16_t*>(base->data[0])[0] == 64);
  assert(reinterpret_cast<uint16_t*>(shaped->data[0])[0] == 864);
  shaped_mapping->nlq[0].linear_deadzone_threshold = 1024;
  shaped_mapping->nlq[1].linear_deadzone_threshold = 1024;
  shaped_mapping->nlq[2].linear_deadzone_threshold = 1024;
  AVFrame* deadzone = rillight_color::CopyFrameForCompose(base);
  assert(deadzone);
  auto* deadzone_metadata = reinterpret_cast<AVDOVIMetadata*>(
      av_frame_get_side_data(deadzone, AV_FRAME_DATA_DOVI_METADATA)->data);
  std::memcpy(deadzone_metadata, shaped_metadata, av_frame_get_side_data(
      shaped, AV_FRAME_DATA_DOVI_METADATA)->size);
  assert(!rillight_color::ComposeFelResidual(deadzone, layer));
  assert(reinterpret_cast<uint16_t*>(deadzone->data[0])[0] == 64);
  assert(dovi_frame_decision(7, 6, 1, 1, 1, 0).reconstruction != RILLIGHT_CORE_DOVI_RECON_FEL);
  const uint8_t length_prefixed[] = {
      0, 0, 0, 4, 0x02, 0x01, 0xaa, 0xbb,
      0, 0, 0, 8, 0x7e, 0x01, 0x40, 0x01, 0x00, 0x00, 0x03, 0x00};
  std::vector<uint8_t> extracted;
  assert(rillight_dovi::ExtractInterleavedEnhancement(
      length_prefixed, sizeof(length_prefixed), 4, &extracted));
  const uint8_t expected_el[] = {0, 0, 0, 1, 0x40, 0x01, 0x00, 0x00, 0x03, 0x00};
  assert(extracted.size() == sizeof(expected_el));
  assert(std::memcmp(extracted.data(), expected_el, sizeof(expected_el)) == 0);
  const uint8_t annexb[] = {
      0, 0, 0, 1, 0x02, 0x01, 0xaa, 0xbb,
      0, 0, 1, 0x7e, 0x01, 0x40, 0x01, 0x11, 0x22};
  assert(rillight_dovi::ExtractInterleavedEnhancement(annexb, sizeof(annexb), 0, &extracted));
  const uint8_t expected_annexb[] = {0, 0, 0, 1, 0x40, 0x01, 0x11, 0x22};
  assert(extracted.size() == sizeof(expected_annexb));
  assert(std::memcmp(extracted.data(), expected_annexb, sizeof(expected_annexb)) == 0);
  const uint8_t base_only[] = {0, 0, 0, 1, 0x02, 0x01, 0xaa, 0xbb};
  assert(rillight_dovi::ExtractInterleavedEnhancement(base_only, sizeof(base_only), 0, &extracted));
  assert(extracted.empty());
  const uint8_t truncated[] = {0, 0, 0, 8, 0x7e, 0x01};
  assert(!rillight_dovi::ExtractInterleavedEnhancement(truncated, sizeof(truncated), 4, &extracted));
  assert(extracted.empty());
  const auto profile5 = dovi_frame_decision(5, 0, 0, 0, 0, 0);
  assert(profile5.error == RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI);
  assert(profile5.emit_picture == 0 && profile5.use_rpu == 0);
  assert(dovi_present_output_kind(RILLIGHT_CORE_VIDEO_D3D11, 1, 0, 1) ==
         RILLIGHT_CORE_VIDEO_OUT_HDR);
  assert(dovi_present_output_kind(RILLIGHT_CORE_VIDEO_RGBA16F, 0, 1, 1) ==
         RILLIGHT_CORE_VIDEO_OUT_HDR);
  assert(dovi_present_output_kind(RILLIGHT_CORE_VIDEO_RGBA, 0, 0, 1) ==
         RILLIGHT_CORE_VIDEO_OUT_SDR);
  assert(dovi_present_output_kind(RILLIGHT_CORE_VIDEO_MEDIACODEC, 0, 0, 1) ==
         RILLIGHT_CORE_VIDEO_OUT_DOLBY_VISION);
  assert(dovi_android_color_output_kind(1) == RILLIGHT_CORE_VIDEO_OUT_HDR);
  assert(dovi_android_color_output_kind(0) != RILLIGHT_CORE_VIDEO_OUT_DOLBY_VISION);
  av_frame_free(&deadzone);
  av_frame_free(&shaped);
  av_frame_free(&unchanged);
  av_frame_free(&neutral);
  av_frame_free(&layer);
  av_frame_free(&owned);
  av_frame_free(&alias);
  av_frame_free(&base);
}
