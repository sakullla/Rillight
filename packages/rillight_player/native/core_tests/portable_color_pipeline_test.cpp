#include "../core/dovi_color_metadata.h"
#include "../core/dovi_enhancement.h"
#include "../core/dovi_profile.h"
#include "../core/portable_color_pipeline.h"
#include "color_pipeline_fixtures.h"

#include <limits>

extern "C" {
#include <libavcodec/avcodec.h>
}

bool HevcAnnexProducesPicture(const std::vector<uint8_t>& annexb) {
  av_log_set_level(AV_LOG_QUIET);
  const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
  if (!codec) return false;
  AVCodecContext* context = avcodec_alloc_context3(codec);
  if (!context || avcodec_open2(context, codec, nullptr) < 0) {
    avcodec_free_context(&context);
    return false;
  }
  AVPacket* packet = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  bool produced = false;
  if (packet && frame && !annexb.empty() &&
      annexb.size() <= static_cast<size_t>(std::numeric_limits<int>::max()) &&
      av_new_packet(packet, static_cast<int>(annexb.size())) >= 0) {
    std::memcpy(packet->data, annexb.data(), annexb.size());
    if (avcodec_send_packet(context, packet) >= 0) {
      avcodec_send_packet(context, nullptr);
      while (avcodec_receive_frame(context, frame) >= 0) {
        if (frame->width > 0 && frame->height > 0) produced = true;
        av_frame_unref(frame);
      }
    }
  }
  av_frame_free(&frame);
  av_packet_free(&packet);
  avcodec_free_context(&context);
  return produced;
}

std::vector<uint8_t> RewriteHevcTypes(const uint8_t* data, size_t size, int type) {
  std::vector<uint8_t> out(data, data + size);
  rillight_dovi::ForEachHevcNal(out.data(), out.size(), 0, [&](const uint8_t* nal, size_t nal_size) {
    if (nal_size < 2) return;
    const auto index = static_cast<size_t>(nal - out.data());
    out[index] = static_cast<uint8_t>((out[index] & 0x81) | ((type & 63) << 1));
  });
  return out;
}

std::vector<uint8_t> WithoutNalType(const std::vector<uint8_t>& annexb, int type) {
  std::vector<uint8_t> out;
  rillight_dovi::ForEachHevcNal(annexb.data(), annexb.size(), 0, [&](const uint8_t* nal, size_t nal_size) {
    if (nal_size < 2 || ((nal[0] >> 1) & 0x3f) == type) return;
    rillight_dovi::AppendAnnexB(&out, nal, nal_size);
  });
  return out;
}

std::vector<uint8_t> RetypeNal(const std::vector<uint8_t>& annexb, int from, int to) {
  std::vector<uint8_t> out;
  rillight_dovi::ForEachHevcNal(annexb.data(), annexb.size(), 0, [&](const uint8_t* nal, size_t nal_size) {
    if (nal_size < 2) return;
    std::vector<uint8_t> copy(nal, nal + nal_size);
    if (((copy[0] >> 1) & 0x3f) == from)
      copy[0] = static_cast<uint8_t>((copy[0] & 0x81) | ((to & 63) << 1));
    rillight_dovi::AppendAnnexB(&out, copy.data(), copy.size());
  });
  return out;
}

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
  // Non-identity reshape: 0.25 + 0.5x. coef_log2_denom 10 makes 256 and 512
  // those coefficients. An identity curve hides add-then-reshape.
  auto* base_header = av_dovi_get_header(base_metadata);
  base_header->coef_log2_denom = 10;
  base_header->el_bit_depth = 10;
  auto* base_mapping = av_dovi_get_mapping(base_metadata);
  for (int channel = 0; channel < 3; ++channel) {
    auto& curve = base_mapping->curves[channel];
    curve.poly_order[0] = 1;
    curve.poly_coef[0][0] = 256;
    curve.poly_coef[0][1] = 512;
    curve.poly_coef[0][2] = 0;
  }
  // av_frame_clone shares the pixel buffers. Composition must not write them.
  AVFrame* alias = av_frame_clone(base);
  assert(alias && alias->data[0] == base->data[0]);
  AVFrame* layer = Picture(AV_PIX_FMT_YUV420P10LE, 800);
  assert(layer);
  const auto fallback = dovi_frame_decision(7, 6, 1, 1, 1, 0);
  assert(fallback.reconstruction == RILLIGHT_CORE_DOVI_RECON_BASE_FALLBACK);
  assert(fallback.reconstruction != RILLIGHT_CORE_DOVI_RECON_FEL);
  assert(fallback.emit_picture == 1 && fallback.use_rpu == 0);
  const auto completed = dovi_frame_decision(7, 6, 1, 1, 1, 1);
  assert(completed.reconstruction == RILLIGHT_CORE_DOVI_RECON_FEL);
  assert(completed.use_rpu == 1);
  auto order = [&](bool nlq) {
    if (nlq) {
      base_mapping->nlq_method_idc = AV_DOVI_NLQ_LINEAR_DZ;
      for (int channel = 0; channel < 3; ++channel) {
        base_mapping->nlq[channel].nlq_offset = 0;
        base_mapping->nlq[channel].linear_deadzone_slope = 1024;
        base_mapping->nlq[channel].linear_deadzone_threshold = 0;
        base_mapping->nlq[channel].vdr_in_max = 1024;
      }
    } else {
      base_mapping->nlq_method_idc = AV_DOVI_NLQ_NONE;
      for (int channel = 0; channel < 3; ++channel)
        base_mapping->nlq[channel] = AVDOVINLQParams{};
    }
    rillight_color::FelResidual fel;
    assert(rillight_color::LoadFelResidual(base, layer, &fel));
    assert(fel.differs);
    const double expected = nlq ? 800.0 / 1023.0 : (800.0 - 512.0) / 1023.0;
    assert(std::fabs(fel.Delta(0, 800) - expected) < 1e-9);
    AVFrame* summed = rillight_color::CopyFrameForCompose(base);
    assert(summed && summed->data[0] != base->data[0]);
    const auto quantize = [&](int channel, int base_code, int el_code) {
      const double sum = base_code / 1023.0 + fel.Delta(channel, el_code);
      return static_cast<uint16_t>(std::clamp(static_cast<int>(std::lround(
          std::clamp(sum, 0.0, 1.0) * 1023.0)), 0, 1023));
    };
    const uint16_t luma = quantize(0, 64, 800);
    const uint16_t u = quantize(1, 512, 512);
    const uint16_t v = quantize(2, 512, 512);
    for (int y = 0; y < summed->height; ++y)
      std::fill_n(reinterpret_cast<uint16_t*>(summed->data[0] + y * summed->linesize[0]),
                  summed->width, luma);
    for (int y = 0; y < summed->height / 2; ++y) {
      std::fill_n(reinterpret_cast<uint16_t*>(summed->data[1] + y * summed->linesize[1]),
                  summed->width / 2, u);
      std::fill_n(reinterpret_cast<uint16_t*>(summed->data[2] + y * summed->linesize[2]),
                  summed->width / 2, v);
    }
    std::vector<uint8_t> base_pixels(32 * 24 * 4);
    std::vector<uint8_t> fel_pixels(32 * 24 * 4);
    std::vector<uint8_t> summed_pixels(32 * 24 * 4);
    base_header->disable_residual_flag = 1;
    assert(pipeline.Render(base, 32, 24, true, base_pixels.data(), 32 * 4));
    base_header->disable_residual_flag = 0;
    assert(pipeline.Render(base, 32, 24, true, fel_pixels.data(), 32 * 4, layer));
    base_header->disable_residual_flag = 1;
    assert(pipeline.Render(summed, 32, 24, true, summed_pixels.data(), 32 * 4));
    assert(reinterpret_cast<uint16_t*>(base->data[0])[0] == 64);
    assert(reinterpret_cast<uint16_t*>(alias->data[0])[0] == 64);
    assert(fel_pixels != base_pixels);
    assert(fel_pixels != summed_pixels);
    av_frame_free(&summed);
  };
  order(false);
  order(true);
  base_mapping->nlq_method_idc = AV_DOVI_NLQ_NONE;
  for (int channel = 0; channel < 3; ++channel)
    base_mapping->nlq[channel] = AVDOVINLQParams{};
  AVFrame* neutral = Picture(AV_PIX_FMT_YUV420P10LE, 512);
  rillight_color::FelResidual neutral_fel;
  assert(neutral && rillight_color::LoadFelResidual(base, neutral, &neutral_fel));
  assert(!neutral_fel.differs);
  assert(reinterpret_cast<uint16_t*>(base->data[0])[0] == 64);
  assert(dovi_frame_decision(7, 6, 1, 1, 1, 0).reconstruction != RILLIGHT_CORE_DOVI_RECON_FEL);
  base_mapping->nlq_method_idc = AV_DOVI_NLQ_LINEAR_DZ;
  for (int channel = 0; channel < 3; ++channel) {
    base_mapping->nlq[channel].nlq_offset = 0;
    base_mapping->nlq[channel].linear_deadzone_slope = 1024;
    base_mapping->nlq[channel].linear_deadzone_threshold = 1024;
    base_mapping->nlq[channel].vdr_in_max = 1024;
  }
  rillight_color::FelResidual deadzone;
  assert(rillight_color::LoadFelResidual(base, layer, &deadzone));
  assert(!deadzone.differs);
  assert(reinterpret_cast<uint16_t*>(base->data[0])[0] == 64);
  assert(dovi_frame_decision(7, 6, 1, 1, 1, 0).reconstruction != RILLIGHT_CORE_DOVI_RECON_FEL);
  base_mapping->nlq_method_idc = static_cast<AVDOVINLQMethod>(-2);
  base_mapping->nlq[0].linear_deadzone_threshold = 0;
  rillight_color::FelResidual rejected;
  assert(!rillight_color::LoadFelResidual(base, layer, &rejected));
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
  const uint8_t rewritten_slice[] = {0, 0, 0, 1, 0x7e, 0x01, 0x80, 0x11};
  assert(rillight_dovi::ExtractInterleavedEnhancement(
      rewritten_slice, sizeof(rewritten_slice), 0, &extracted));
  const uint8_t expected_slice[] = {0, 0, 0, 1, 0x02, 0x01, 0x80, 0x11};
  assert(extracted.size() == sizeof(expected_slice));
  assert(std::memcmp(extracted.data(), expected_slice, sizeof(expected_slice)) == 0);
  // The RBSP high bit is set, so this is not a nested NAL header.
  const uint8_t rewritten_vps[] = {
      0, 0, 0, 6, 0x7e, 0x01, 0x8c, 0x01, 0xff, 0xff};
  assert(rillight_dovi::ExtractInterleavedEnhancement(
      rewritten_vps, sizeof(rewritten_vps), 4, &extracted));
  const uint8_t expected_vps[] = {0, 0, 0, 1, 0x40, 0x01, 0x8c, 0x01, 0xff, 0xff};
  assert(extracted.size() == sizeof(expected_vps));
  assert(std::memcmp(extracted.data(), expected_vps, sizeof(expected_vps)) == 0);
  const uint8_t rewritten_sps[] = {
      0, 0, 0, 1, 0x7e, 0x01,
      0x81, 0x02, 0x20, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
  assert(rillight_dovi::ExtractInterleavedEnhancement(
      rewritten_sps, sizeof(rewritten_sps), 0, &extracted));
  const uint8_t expected_sps[] = {
      0, 0, 0, 1, 0x42, 0x01,
      0x81, 0x02, 0x20, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
  assert(extracted.size() == sizeof(expected_sps));
  assert(std::memcmp(extracted.data(), expected_sps, sizeof(expected_sps)) == 0);
  // One real Main-profile access unit: VPS, SPS, PPS and IDR_N_LP. Rewriting
  // every nal_unit_type to 63 must come back as a picture. Dropping the PPS,
  // or labeling that IDR as TRAIL_R, must not.
  const uint8_t hevc_access_unit[] = {
      0, 0, 0, 1, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00,
      0x9f, 0xa8, 0x00, 0x00, 0x03, 0x00, 0x00, 0x1e, 0xba, 0x02, 0x40,
      0, 0, 0, 1, 0x42, 0x01, 0x01, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0x9f, 0xa8, 0x00,
      0x00, 0x03, 0x00, 0x00, 0x1e, 0xa0, 0x20, 0x81, 0x05, 0x96, 0xe9, 0x29, 0x30, 0xbc,
      0x05, 0xa0, 0x20, 0x00, 0x00, 0x03, 0x00, 0x20, 0x00, 0x00, 0x03, 0x00, 0x21,
      0, 0, 0, 1, 0x44, 0x01, 0xc0, 0x71, 0x81, 0x12,
      0, 0, 0, 1, 0x28, 0x01, 0xad, 0xe0, 0xd1, 0x17, 0xce, 0x73, 0x23, 0x8b, 0x80};
  assert(HevcAnnexProducesPicture(
      std::vector<uint8_t>(hevc_access_unit, hevc_access_unit + sizeof(hevc_access_unit))));
  const std::vector<uint8_t> wrapped = RewriteHevcTypes(
      hevc_access_unit, sizeof(hevc_access_unit), 63);
  assert(rillight_dovi::ExtractInterleavedEnhancement(
      wrapped.data(), wrapped.size(), 0, &extracted));
  assert(HevcAnnexProducesPicture(extracted));
  assert(!HevcAnnexProducesPicture(WithoutNalType(extracted, 34)));
  assert(!HevcAnnexProducesPicture(RetypeNal(extracted, 20, 1)));
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
  av_frame_free(&neutral);
  av_frame_free(&layer);
  av_frame_free(&alias);
  av_frame_free(&base);
}
