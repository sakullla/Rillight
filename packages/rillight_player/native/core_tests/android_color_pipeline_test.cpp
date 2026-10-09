#include "../core/android_color_pipeline.h"
#include "../core/portable_color_pipeline.h"
#include "color_pipeline_fixtures.h"

#include <media/NdkImageReader.h>
#include <chrono>
#include <cstdio>
#include <thread>

int main() {
  AImageReader* reader = nullptr;
  assert(AImageReader_new(64, 48, AIMAGE_FORMAT_RGBA_8888, 2, &reader) == AMEDIA_OK);
  ANativeWindow* window = nullptr;
  assert(AImageReader_getWindow(reader, &window) == AMEDIA_OK);
  int cases = 0;
  {
    AndroidColorPipeline gpu;
    PortableColorPipeline cpu;
    // Alternate formats and polynomial/MMR programs on the same output. Solid
    // colored samples avoid mistaking different resize filters for color errors.
    for (int mode = 0; mode < 6; ++mode) {
      for (const auto format : {AV_PIX_FMT_P010LE, AV_PIX_FMT_NV12}) {
        const std::pair<int, int> chroma_samples[] = {
          {120, 148}, {0, 0}, {16, 240}, {64, 192}, {127, 128},
          {128, 128}, {192, 64}, {240, 16}, {255, 255},
        };
        for (const auto& chroma : chroma_samples) {
          for (int level : {1, 16, 32, 63, 64, 65, 96, 127, 128, 129, 160, 224}) {
            AVFrame* frame = av_frame_alloc();
            frame->format = format; frame->width = 64; frame->height = 48;
            frame->color_range = AVCOL_RANGE_JPEG;
            assert(av_frame_get_buffer(frame, 32) == 0);
            for (int p = 0; p < 2; ++p) {
              for (int y = 0; y < frame->height / (p ? 2 : 1); ++y) {
                for (int x = 0; x < frame->width; ++x) {
                  const int value = p ? (x % 2 ? chroma.second : chroma.first) : level;
                  if (format == AV_PIX_FMT_P010LE)
                    reinterpret_cast<uint16_t*>(frame->data[p] + y * frame->linesize[p])[x] =
                        static_cast<uint16_t>((value * 1023 / 255) << 6);
                  else frame->data[p][y * frame->linesize[p] + x] = static_cast<uint8_t>(value);
                }
              }
            }
            auto* metadata = Metadata(frame);
            av_dovi_get_header(metadata)->coef_log2_denom = 8;
            auto* mapping = av_dovi_get_mapping(metadata);
            const int maximum = format == AV_PIX_FMT_P010LE ? 1023 : 255;
            for (int channel = 0; channel < 3; ++channel) {
              auto& curve = mapping->curves[channel];
              curve.num_pivots = 9;
              for (int i = 0; i <= 8; ++i) curve.pivots[i] = maximum * i / 8;
              for (int i = 0; i < 8; ++i) {
                curve.poly_order[i] = 1;
                curve.poly_coef[i][0] = i * 8;
                curve.poly_coef[i][1] = 256 - i * 8;
                if (mode >= 4) {
                  curve.poly_coef[i][0] = 0;
                  curve.poly_coef[i][1] = mode == 5 ? 256 : 0;
                  curve.poly_coef[i][2] = mode == 4 ? 256 : 0;
                  curve.poly_order[i] = mode == 4 ? 2 : 1;
                } else if (mode) {
                  curve.mapping_idc[i] = AV_DOVI_MAPPING_MMR;
                  curve.mmr_order[i] = mode;
                  curve.mmr_constant[i] = i;
                  curve.mmr_coef[i][0][channel] = 224;
                  if (mode >= 2) curve.mmr_coef[i][1][channel] = 32;
                  if (mode >= 3) curve.mmr_coef[i][2][channel] = 16;
                }
              }
            }
            std::vector<uint8_t> reference(64 * 48 * 4);
            assert(cpu.Render(frame, 64, 48, true, reference.data(), 64 * 4));
            assert(gpu.Render(frame, window, false));
            AImage* image = nullptr;
            for (int retry = 0; retry < 100 && !image; ++retry) {
              AImageReader_acquireNextImage(reader, &image);
              if (!image) std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
            assert(image);
            uint8_t* pixels = nullptr; int length = 0, stride = 0;
            assert(AImage_getPlaneData(image, 0, &pixels, &length) == AMEDIA_OK);
            assert(AImage_getPlaneRowStride(image, 0, &stride) == AMEDIA_OK);
            int worst = 0;
            for (int y = 0; y < 48; ++y)
              for (int x = 0; x < 64 * 4; ++x)
                worst = std::max(worst, std::abs(int(pixels[y * stride + x]) - reference[y * 64 * 4 + x]));
            if (worst > 3) std::fprintf(stderr, "mode=%d format=%d level=%d uv=%d,%d error=%d\n", mode, format, level, chroma.first, chroma.second, worst);
            assert(worst <= 3);
            AImage_delete(image); av_frame_free(&frame); ++cases;
          }
        }
      }
    }
  }
  AImageReader_delete(reader);
  std::printf("Android GPU/CPU Dolby color comparison: %d cases passed\n", cases);
}
