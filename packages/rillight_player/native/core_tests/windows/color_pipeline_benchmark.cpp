// Synthetic mapping/presentation benchmark, not a movie or hardware acceptance
// test. Compare the former SDR subtitle readback route with texture + overlay.
#include "../../core/windows_color_pipeline.h"
#include "../../../windows/gpu_present.h"
#include "../color_pipeline_fixtures.h"
#include <chrono>
#include <cstdio>
extern "C" {
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_d3d11va.h>
}

int main() {
  AVBufferRef* device = nullptr;
  assert(av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_D3D11VA,
                               nullptr, nullptr, 0) == 0);
  AVBufferRef* frames = av_hwframe_ctx_alloc(device);
  assert(frames);
  auto* pool = reinterpret_cast<AVHWFramesContext*>(frames->data);
  pool->format = AV_PIX_FMT_D3D11; pool->sw_format = AV_PIX_FMT_P010LE;
  pool->width = 3840; pool->height = 2160; pool->initial_pool_size = 2;
  assert(av_hwframe_ctx_init(frames) == 0);
  AVFrame* software = av_frame_alloc();
  AVFrame* hardware = av_frame_alloc();
  assert(software && hardware);
  software->format = AV_PIX_FMT_P010LE;
  software->width = 3840; software->height = 2160;
  software->color_trc = AVCOL_TRC_SMPTE2084;
  software->color_primaries = AVCOL_PRI_BT2020;
  assert(av_frame_get_buffer(software, 32) == 0);
  for (int y = 0; y < software->height; ++y) {
    auto* row = reinterpret_cast<uint16_t*>(software->data[0] + y * software->linesize[0]);
    for (int x = 0; x < software->width; ++x)
      row[x] = static_cast<uint16_t>((128 + (x + y) % 640) << 6);
  }
  for (int y = 0; y < software->height / 2; ++y)
    std::fill_n(reinterpret_cast<uint16_t*>(software->data[1] + y * software->linesize[1]),
                software->width, uint16_t{512 << 6});
  auto* metadata = Metadata(software);
  av_dovi_get_header(metadata)->bl_video_full_range_flag = 1;
  for (int c = 0; c < 3; ++c) {
    auto& curve = av_dovi_get_mapping(metadata)->curves[c];
    curve.mapping_idc[0] = AV_DOVI_MAPPING_MMR;
    curve.mmr_order[0] = 3;
    curve.mmr_coef[0][0][c] = 1;
  }
  assert(av_hwframe_get_buffer(frames, hardware, 0) == 0);
  assert(av_hwframe_transfer_data(hardware, software, 0) == 0);
  assert(av_frame_copy_props(hardware, software) == 0);
  WindowsColorPipeline pipeline;
  rillight_windows::GpuPresenter presenter(nullptr);
  const uint8_t white[] = {128,128,128,128};
  RillightCoreSubtitleOverlay overlay{sizeof(overlay),0,0,1,1,4,white};
  for (const int width : {1920, 3840}) {
    const int height = width * 9 / 16;
    std::vector<uint8_t> rgba(static_cast<size_t>(width) * height * 4);
    for (const bool readback : {true, false}) {
      std::vector<double> samples;
      for (int iteration = 0; iteration < 35; ++iteration) {
        const auto start = std::chrono::steady_clock::now();
        RillightCoreFrame frame{};
        frame.width = width; frame.height = height;
        frame.sar_num = frame.sar_den = 1;
        Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
        if (readback) {
          assert(pipeline.Render(hardware, width, height, true, rgba.data(), width * 4));
          frame.type = RILLIGHT_CORE_VIDEO_RGBA; frame.data = rgba.data();
          frame.stride = width * 4; frame.data_size = frame.stride * height;
        } else {
          texture.Attach(static_cast<ID3D11Texture2D*>(
              pipeline.RenderTexture(hardware, width, height, true)));
          assert(texture);
          frame.type = RILLIGHT_CORE_VIDEO_D3D11;
        }
        auto presented = presenter.Present(frame, texture.Get(), width, height, &overlay);
        assert(presented);
        const double ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - start).count();
        if (iteration >= 5) samples.push_back(ms);
      }
      std::sort(samples.begin(), samples.end());
      std::printf("{\"route\":\"%s\",\"input\":\"3840x2160 P010 synthetic RPU MMR3\","
                  "\"outputWidth\":%d,\"outputHeight\":%d,\"samples\":%zu,"
                  "\"medianMs\":%.3f,\"p95Ms\":%.3f}\n",
                  readback ? "readback-upload-overlay" : "texture-overlay", width, height,
                  samples.size(), samples[samples.size()/2], samples[samples.size()*95/100]);
    }
  }
  av_frame_free(&hardware); av_frame_free(&software);
  av_buffer_unref(&frames); av_buffer_unref(&device);
}
