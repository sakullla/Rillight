#include "../../core/macos_color_pipeline.h"
#include "../../core/portable_color_pipeline.h"
#include "../color_pipeline_fixtures.h"
#include "../../../macos/rillight_player/Sources/rillight_player/FrameOutput.h"

#include <array>
#include <cstdio>

extern "C" {
#include <libswscale/swscale.h>
}

int main() {
  std::array<float, 4096> pq{}, hlg{};
  for (size_t i = 0; i < pq.size(); ++i) {
    const double x = i / 4095.0;
    const double p = std::pow(x, 1.0 / 78.84375);
    pq[i] = static_cast<float>(10000 * std::pow(std::max(p - .8359375, 0.0) /
        (18.8515625 - 18.6875 * p), 1.0 / .1593017578125));
    hlg[i] = static_cast<float>(1000 * (x <= .5 ? x * x / 3 :
        (std::exp((x - .55991073) / .17883277) + .28466892) / 12));
  }
  MacosColorPipeline gpu;
  PortableColorPipeline cpu;
  int cases = 0;
  for (const auto format : {AV_PIX_FMT_YUV420P10LE, AV_PIX_FMT_P010LE,
                            AV_PIX_FMT_YUV420P12LE, AV_PIX_FMT_P012LE,
                            AV_PIX_FMT_YUV420P16LE, AV_PIX_FMT_P016LE}) {
    const int depth = av_pix_fmt_desc_get(format)->comp[0].depth;
    for (int mode = 0; mode < 4; ++mode) {
      auto* frame = Picture(format, static_cast<uint16_t>(512u << (depth - 10)));
      const bool packed = format == AV_PIX_FMT_P010LE ||
                          format == AV_PIX_FMT_P012LE || format == AV_PIX_FMT_P016LE;
      // Colored, nonuniform samples exercise gamut conversion and chroma,
      // rather than accepting a grayscale-only shader comparison.
      for (int row = 0; row < frame->height; ++row) {
        auto* y = reinterpret_cast<uint16_t*>(frame->data[0] + row * frame->linesize[0]);
        for (int x = 0; x < frame->width; ++x) {
          const uint16_t code = static_cast<uint16_t>((64 + (x * 13 + row * 7) % 877)
                                                       << (depth - 10));
          y[x] = packed ? code << (16 - depth) : code;
        }
      }
      for (int row = 0; row < frame->height / 2; ++row) {
        auto* u = reinterpret_cast<uint16_t*>(frame->data[1] + row * frame->linesize[1]);
        auto* v = packed ? u + 1 : reinterpret_cast<uint16_t*>(
            frame->data[2] + row * frame->linesize[2]);
        for (int x = 0; x < frame->width / 2; ++x) {
          uint16_t a = static_cast<uint16_t>((300 + x * 7) << (depth - 10));
          uint16_t b = static_cast<uint16_t>((650 - row * 9) << (depth - 10));
          u[x * (packed ? 2 : 1)] = packed ? a << (16 - depth) : a;
          v[x * (packed ? 2 : 1)] = packed ? b << (16 - depth) : b;
        }
      }
      const bool dovi = mode >= 2;
      if (dovi) {
        auto* metadata = Metadata(frame);
        if (mode == 3) {
          auto* mapping = av_dovi_get_mapping(metadata);
          for (int channel = 0; channel < 3; ++channel) {
            auto& curve = mapping->curves[channel];
            curve.mapping_idc[0] = AV_DOVI_MAPPING_MMR;
            curve.mmr_order[0] = 1;
            curve.mmr_coef[0][0][channel] = 1;
          }
        }
      }
      frame->color_trc = mode == 1 ? AVCOL_TRC_ARIB_STD_B67 : AVCOL_TRC_SMPTE2084;
      for (const auto range : {AVCOL_RANGE_MPEG, AVCOL_RANGE_JPEG}) {
        frame->color_range = range;
        for (auto size : {std::pair<int, int>{32, 24}, {63, 47}}) {
          rillight_color::Constants constants{};
          constants.visible = {1, 1, 1, 1000};
          if (dovi) {
            assert(rillight_color::DoviConstants(frame, &constants));
          } else {
            constants.nonlinear[0] = {1, 0, 1.4746f, 0};
            constants.nonlinear[1] = {1, -.164553f, -.571353f, 0};
            constants.nonlinear[2] = {1, 1.8814f, 0, 0};
          }
          auto* samples = av_frame_alloc();
          samples->width = size.first;
          samples->height = size.second;
          samples->format = AV_PIX_FMT_YUV444P16LE;
          assert(av_frame_get_buffer(samples, 32) == 0);
          samples->color_range = frame->color_range;
          samples->colorspace = frame->colorspace;
          samples->color_primaries = frame->color_primaries;
          samples->color_trc = frame->color_trc;
          auto* scaler = sws_alloc_context();
          scaler->threads = 4;
          scaler->flags = SWS_BILINEAR;
          scaler->backends = SWS_BACKEND_LEGACY;
          assert(sws_scale_frame(scaler, samples, frame) >= 0);
          const int stride = size.first * 8 + 16;
          std::vector<uint16_t> reference(stride * size.second / 2, 0xabcd);
          auto observed = reference;
          assert(cpu.RenderLinearHalf(frame, size.first, size.second, dovi,
                                       reference.data(), stride));
          assert(gpu.RenderLinearHalf(samples, constants, depth,
              range == AVCOL_RANGE_JPEG, dovi, frame->color_trc,
              pq.data(), hlg.data(), observed.data(), stride));
          for (size_t i = 0; i < reference.size(); ++i) {
            const float expected = rillight_macos::HalfToFloat(reference[i]);
            const float actual = rillight_macos::HalfToFloat(observed[i]);
            assert(std::abs(expected - actual) <= .002f *
                   std::max(1.0f, std::abs(expected)));
          }
          ++cases;
          av_frame_free(&samples);
          sws_free_context(&scaler);
        }
      }
      av_frame_free(&frame);
    }
  }
  assert(!gpu.RenderLinearHalf(nullptr, {}, 10, false, false,
      AVCOL_TRC_SMPTE2084, pq.data(), hlg.data(), nullptr, 0));
  std::printf("%d Metal PQ/HLG/DV polynomial/MMR colored cases match CPU FP16\n", cases);
}
