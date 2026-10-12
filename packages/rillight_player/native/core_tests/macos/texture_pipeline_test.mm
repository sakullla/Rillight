#import <CoreVideo/CoreVideo.h>
#include "../../core/macos_texture_pipeline.h"
#include "../../core/portable_color_pipeline.h"
#define Picture TexturePicture
#include "../color_pipeline_fixtures.h"
#undef Picture
#include <cstdio>
#include <vector>
#include "../../../macos/rillight_player/Sources/rillight_player/MetalFrameOutput.h"
extern "C" {
#include <libavutil/hwcontext.h>
}
namespace {
std::vector<uint8_t> Read(CVPixelBufferRef buffer) {
  assert(CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess);
  auto* data = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(buffer));
  std::vector<uint8_t> copy(
      data, data + CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer));
  CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  return copy;
}
}  // namespace
int main() {
  @autoreleasepool {
    AVBufferRef* device = nullptr;
    assert(av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nullptr, nullptr, 0) ==
           0);
    for (bool ten : {false, true}) {
      AVBufferRef* frames = av_hwframe_ctx_alloc(device);
      auto* pool = reinterpret_cast<AVHWFramesContext*>(frames->data);
      pool->format = AV_PIX_FMT_VIDEOTOOLBOX;
      pool->sw_format = ten ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;
      pool->width = 64;
      pool->height = 48;
      assert(av_hwframe_ctx_init(frames) == 0);
      auto gpu = std::make_unique<MacosTexturePipeline>();
      std::vector<std::shared_ptr<void>> held;
      std::vector<std::vector<uint8_t>> pixels;
      for (int mode = 0; mode < (ten ? 4 : 1); ++mode) {
        AVFrame* source = ten ? TexturePicture(AV_PIX_FMT_P010LE, 512) : av_frame_alloc();
        if (!ten) {
          source->format = AV_PIX_FMT_NV12;
          source->width = 64;
          source->height = 48;
          assert(av_frame_get_buffer(source, 32) == 0);
          for (int y = 0; y < 48; ++y)
            std::memset(source->data[0] + y * source->linesize[0], 126, 64);
          for (int y = 0; y < 24; ++y)
            for (int x = 0; x < 64; x += 2) {
              source->data[1][y * source->linesize[1] + x] = 90;
              source->data[1][y * source->linesize[1] + x + 1] = 170;
            }
          source->colorspace = AVCOL_SPC_BT709;
          source->color_range = AVCOL_RANGE_MPEG;
          source->color_primaries = AVCOL_PRI_BT709;
          source->color_trc = AVCOL_TRC_BT709;
        }
        bool dovi = mode >= 2;
        if (dovi) {
          auto* metadata = Metadata(source);
          if (mode == 3) {
            auto* mapping = av_dovi_get_mapping(metadata);
            for (int c = 0; c < 3; ++c) {
              auto& curve = mapping->curves[c];
              curve.mapping_idc[0] = AV_DOVI_MAPPING_MMR;
              curve.mmr_order[0] = 1;
              curve.mmr_coef[0][0][c] = 1;
            }
          }
        }
        if (mode == 1) source->color_trc = AVCOL_TRC_ARIB_STD_B67;
        if (ten && mode == 0) {
          // Left-sited 4:2:0 chroma needs a half-luma-pixel texture offset.
          // A sharp chroma edge catches the centered-sampler regression that
          // uniform frames and color-patch-center comparisons cannot detect.
          source->chroma_location = AVCHROMA_LOC_LEFT;
          for (int y = 0; y < source->height / 2; ++y) {
            auto* uv = reinterpret_cast<uint16_t*>(source->data[1] + y * source->linesize[1]);
            for (int x = 0; x < source->width / 2; ++x) {
              uv[2 * x] = static_cast<uint16_t>((x < source->width / 4 ? 440 : 600) << 6);
              uv[2 * x + 1] = static_cast<uint16_t>(520 << 6);
            }
          }
        }

        AVFrame* hardware = av_frame_alloc();
        assert(av_hwframe_get_buffer(frames, hardware, 0) == 0);
        assert(av_hwframe_transfer_data(hardware, source, 0) == 0);
        assert(av_frame_copy_props(hardware, source) == 0);
        for (bool linear : {false, true}) {
          auto image = gpu->Render(hardware, 64, 48, dovi, linear);
          assert(image);
          auto buffer = static_cast<CVPixelBufferRef>(image.get());
          assert(CVPixelBufferGetIOSurface(buffer));
          auto observed = Read(buffer);
          if (ten && linear) {
            PortableColorPipeline cpu;
            std::vector<uint16_t> expected(64 * 48 * 4);
            assert(cpu.RenderLinearHalf(source, 64, 48, dovi, expected.data(), 64 * 8));
            for (int y = 0; y < 48; ++y)
              for (int x = 0; x < 64 * 4; ++x) {
                auto* row = reinterpret_cast<const uint16_t*>(
                    observed.data() + y * CVPixelBufferGetBytesPerRow(buffer));
                float a = rillight_macos::HalfToFloat(row[x]),
                      b = rillight_macos::HalfToFloat(expected[y * 64 * 4 + x]);
                assert(std::abs(a - b) <= .003f * std::max(1.0f, std::abs(b)));
              }
          }
          // Retain old textures through subsequent renders and converter destruction.
          held.push_back(image);
          pixels.push_back(observed);
          if (ten && mode == 0) continue;  // Nonuniform color is checked above.
          rillight_macos::MetalFrameOutput fit;
          RillightCoreFrame frame{};
          frame.width = 64;
          frame.height = 48;
          frame.sar_num = 2;
          frame.sar_den = 1;
          frame.has_display_matrix = 1;
          frame.display_matrix[1] = 65536;
          frame.display_matrix[3] = -65536;
          uint8_t sub[] = {128, 0, 0, 128};
          RillightCoreSubtitleOverlay overlay{sizeof(overlay), 0, 0, 1, 1, 4, sub};
          auto fitted = fit.Render(buffer, frame, 120, 90, &overlay);
          assert(fitted && CVPixelBufferGetIOSurface(fitted));
          auto fittedPixels = Read(fitted);
          assert(!fittedPixels.empty());
          CVPixelBufferRelease(fitted);
          assert(Read(buffer) == observed);
          // A uniform premultiplied overlay has an exact reference under every
          // fit/rotation. It also verifies the explicit GPU-failure readback path.
          std::vector<uint8_t> solid(64 * 48 * 4);
          for (size_t pixel = 0; pixel < solid.size(); pixel += 4) {
            solid[pixel] = 128;
            solid[pixel + 3] = 128;
          }
          overlay = {sizeof(overlay), 0, 0, 64, 48, 64 * 4, solid.data()};
          for (int rotation = 0; rotation < 4; ++rotation) {
            const int matrices[4][4] = {{65536, 0, 0, 65536},
                                        {0, 65536, -65536, 0},
                                        {-65536, 0, 0, -65536},
                                        {0, -65536, 65536, 0}};
            frame.display_matrix[0] = matrices[rotation][0];
            frame.display_matrix[1] = matrices[rotation][1];
            frame.display_matrix[3] = matrices[rotation][2];
            frame.display_matrix[4] = matrices[rotation][3];
            auto gpu_fit = fit.Render(buffer, frame, 120, 90, &overlay);
            auto cpu_fit = rillight_macos::CpuFallbackBuffer(buffer, frame, 120, 90, &overlay);
            assert(gpu_fit && cpu_fit);
            const auto a = Read(gpu_fit), b = Read(cpu_fit);
            for (int y = 0; y < 90; ++y)
              for (int x = 0; x < 120 * (linear ? 4 : 4); ++x) {
                if (linear) {
                  const auto* ar = reinterpret_cast<const uint16_t*>(
                      a.data() + y * CVPixelBufferGetBytesPerRow(gpu_fit));
                  const auto* br = reinterpret_cast<const uint16_t*>(
                      b.data() + y * CVPixelBufferGetBytesPerRow(cpu_fit));
                  assert(std::abs(rillight_macos::HalfToFloat(ar[x]) -
                                  rillight_macos::HalfToFloat(br[x])) < .002f);
                } else {
                  assert(std::abs(int(a[y * CVPixelBufferGetBytesPerRow(gpu_fit) + x]) -
                                  int(b[y * CVPixelBufferGetBytesPerRow(cpu_fit) + x])) <= 1);
                }
              }
            CVPixelBufferRelease(gpu_fit);
            CVPixelBufferRelease(cpu_fit);
          }
        }
        av_frame_free(&hardware);
        av_frame_free(&source);
      }
      gpu.reset();
      for (size_t i = 0; i < held.size(); ++i)
        assert(Read(static_cast<CVPixelBufferRef>(held[i].get())) == pixels[i]);
      av_buffer_unref(&frames);
    }
    av_buffer_unref(&device);
    puts("CVMetal NV12/P010 SDR/PQ/HLG/DV polynomial/MMR: GPU-only image path, FP16 reference, "
         "retained IOSurfaces and geometry/subtitle rendering passed");
  }
}
