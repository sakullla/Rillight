#include "../core/portable_color_pipeline.h"
#include "color_pipeline_fixtures.h"

int main() {
  PortableColorPipeline pipeline;
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
}
