#pragma once

// Real decoder textures and core routing, including CPU fallback. Synthetic
// samples intentionally avoid media/credentials and do not prove GUI output.
#include <psapi.h>
#include <dxgi1_4.h>

inline size_t SdrPrivateBytes() {
  PROCESS_MEMORY_COUNTERS_EX memory{};
  assert(GetProcessMemoryInfo(GetCurrentProcess(),
      reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&memory), sizeof(memory)));
  return memory.PrivateUsage;
}

inline uint64_t SdrGpuBytes(AVBufferRef* device) {
  auto* av_device = reinterpret_cast<AVHWDeviceContext*>(device->data);
  auto* d3d = static_cast<AVD3D11VADeviceContext*>(av_device->hwctx);
  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi;
  Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
  Microsoft::WRL::ComPtr<IDXGIAdapter3> memory_adapter;
  if (FAILED(d3d->device->QueryInterface(IID_PPV_ARGS(&dxgi))) ||
      FAILED(dxgi->GetAdapter(&adapter)) || FAILED(adapter.As(&memory_adapter))) return 0;
  DXGI_QUERY_VIDEO_MEMORY_INFO local{}, shared{};
  memory_adapter->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &local);
  memory_adapter->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL, &shared);
  return local.CurrentUsage + shared.CurrentUsage;
}

inline std::vector<uint8_t> SdrTexturePixels(RillightCoreFrame* frame) {
  auto* texture = static_cast<ID3D11Texture2D*>(
      static_cast<VideoOutputFrame*>(frame)->gpu_texture.get());
  assert(texture);
  Microsoft::WRL::ComPtr<ID3D11Device> device;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context;
  texture->GetDevice(&device); device->GetImmediateContext(&context);
  D3D11_TEXTURE2D_DESC desc{}; texture->GetDesc(&desc);
  desc.BindFlags = desc.MiscFlags = 0;
  desc.Usage = D3D11_USAGE_STAGING; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> staging;
  assert(SUCCEEDED(device->CreateTexture2D(&desc, nullptr, &staging)));
  context->CopyResource(staging.Get(), texture);
  D3D11_MAPPED_SUBRESOURCE mapped{};
  assert(SUCCEEDED(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped)));
  std::vector<uint8_t> result(frame->width * frame->height * 4);
  for (int y = 0; y < frame->height; ++y)
    std::memcpy(result.data() + y * frame->width * 4,
        static_cast<const uint8_t*>(mapped.pData) + y * mapped.RowPitch,
        frame->width * 4);
  context->Unmap(staging.Get(), 0);
  return result;
}

inline void CheckHardwareSdrRoute(AVPixelFormat pixel_format, AVColorSpace matrix,
    AVColorRange range, bool gpu, int width = 64, int height = 48,
    bool benchmark = false, bool mapping_failed = false, bool hdr_desktop = false) {
  AVBufferRef* device = nullptr;
  assert(av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_D3D11VA,
                               nullptr, nullptr, 0) == 0);
  AVBufferRef* frames = av_hwframe_ctx_alloc(device);
  assert(frames);
  auto* pool = reinterpret_cast<AVHWFramesContext*>(frames->data);
  pool->format = AV_PIX_FMT_D3D11; pool->sw_format = pixel_format;
  pool->width = width; pool->height = height; pool->initial_pool_size = 2;
  assert(av_hwframe_ctx_init(frames) == 0);
  AVFrame* software = av_frame_alloc();
  AVFrame* hardware = av_frame_alloc();
  assert(software && hardware);
  software->format = pixel_format;
  software->width = width; software->height = height;
  software->color_trc = AVCOL_TRC_BT709;
  software->color_primaries = AVCOL_PRI_BT709;
  software->colorspace = matrix; software->color_range = range;
  assert(av_frame_get_buffer(software, 32) == 0);
  assert(av_hwframe_get_buffer(frames, hardware, 0) == 0);
  RillightCoreImpl core(RillightCoreIo{});
  core.state = RILLIGHT_CORE_OPENING;
  core.gpu_video = gpu; core.video_index = 0; core.subtitle_index = 1;
  core.hdr_video = hdr_desktop;
  core.session = core.timeline = 1;
  core.output_width = benchmark ? width : 37;
  core.output_height = benchmark ? height : 29;
  AVFormatContext* format = avformat_alloc_context();
  auto* stream = avformat_new_stream(format, nullptr);
  assert(stream);
  stream->time_base = {1, 25};
  stream->codecpar->codec_type = AVMEDIA_TYPE_VIDEO;
  stream->codecpar->codec_id = AV_CODEC_ID_H264;
  VideoScale scale;
  scale.hardware_color_failed = mapping_failed;
  const bool texture_expected = gpu && !mapping_failed;
  std::vector<double> timings;
  size_t peak_private = 0;
  uint64_t peak_gpu = 0;
  const size_t before = SdrPrivateBytes();
  for (int iteration = 0; iteration < (benchmark ? 160 : 3); ++iteration) {
    // Neutral endpoints plus a chromatic patch distinguish 601 from 709.
    const int luma = iteration % 3 == 0 ? (range == AVCOL_RANGE_JPEG ? 0 : 16) :
        iteration % 3 == 1 ? (range == AVCOL_RANGE_JPEG ? 255 : 235) : 128;
    const int u = iteration % 3 == 2 ? 96 : 128;
    const int v = iteration % 3 == 2 ? 192 : 128;
    for (int plane = 0; plane < 2; ++plane) {
      for (int y = 0; y < height / (plane + 1); ++y) {
        auto* row = software->data[plane] + y * software->linesize[plane];
        for (int x = 0; x < width; ++x) {
          const int code = plane ? (x % 2 ? v : u) : luma;
          if (pixel_format == AV_PIX_FMT_NV12) row[x] = static_cast<uint8_t>(code);
          else reinterpret_cast<uint16_t*>(row)[x] = static_cast<uint16_t>(code << 8);
        }
      }
    }
    assert(av_hwframe_transfer_data(hardware, software, 0) == 0);
    assert(av_frame_copy_props(hardware, software) == 0);
    const auto started = Clock::now();
    assert(convert_video_frame(&core, format, hardware, 0, RILLIGHT_CORE_HW_D3D11,
        &scale, &core.subtitle_cues, &core.ass, 1, 1, &core.subtitle_mutex) == 0);
    const double ms = std::chrono::duration<double, std::milli>(Clock::now() - started).count();
    assert(core.video.size() == 1);
    const auto type = texture_expected ? RILLIGHT_CORE_VIDEO_D3D11 : RILLIGHT_CORE_VIDEO_RGBA;
    auto* ready = rillight_core_take_frame(reinterpret_cast<RillightCore*>(&core), type);
    assert(ready && ready->type == type);
    assert(core.video_output_kind == RILLIGHT_CORE_VIDEO_OUT_SDR);
    assert(ready->stride == ready->width * 4);
    assert(ready->data_size == ready->width * ready->height * 4);
    assert((scale.downloaded == nullptr) == texture_expected);
    assert((scale.context == nullptr) == texture_expected);
    assert(core.video_processing.summary.find(texture_expected ? "color=gpu-sdr" :
        "color=download+swscale") == 0);
    if (!benchmark) {
      const auto pixels = texture_expected ? SdrTexturePixels(ready) :
          std::vector<uint8_t>(ready->data, ready->data + ready->data_size);
      const double maximum = pixel_format == AV_PIX_FMT_NV12 ? 255.0 : 255.75;
      const bool full = range == AVCOL_RANGE_JPEG;
      const double yy = full ? luma / maximum : (luma - 16) / 219.0;
      const double cb = (u - 128) / (full ? maximum : 224.0);
      const double cr = (v - 128) / (full ? maximum : 224.0);
      const bool bt709 = matrix == AVCOL_SPC_BT709;
      const double rgb[] = {yy + (bt709 ? 1.5748 : 1.402) * cr,
          yy - (bt709 ? .187324 : .344136) * cb - (bt709 ? .468124 : .714136) * cr,
          yy + (bt709 ? 1.8556 : 1.772) * cb};
      for (size_t i = 0; i < pixels.size(); i += 4) {
        for (int c = 0; c < 3; ++c)
          assert(std::abs(static_cast<int>(pixels[i+c]) -
              static_cast<int>(std::lround(std::clamp(rgb[c], 0.0, 1.0) * 255))) <= 3);
        assert(pixels[i+3] == 255);
      }
    }
    rillight_core_release_frame(ready);
    peak_private = std::max(peak_private, SdrPrivateBytes());
    peak_gpu = std::max(peak_gpu, SdrGpuBytes(device));
    if (iteration >= 20) timings.push_back(ms);
  }
  if (benchmark) {
    std::sort(timings.begin(), timings.end());
    std::printf("{\"source\":\"SDR\",\"gpu\":%s,\"width\":%d,\"height\":%d,"
        "\"medianMs\":%.3f,\"p95Ms\":%.3f,\"privateBefore\":%zu,\"privatePeak\":%zu,\"gpuPeak\":%llu}\n",
        gpu ? "true" : "false", width, height, timings[timings.size()/2],
        timings[timings.size()*95/100], before, peak_private,
        static_cast<unsigned long long>(peak_gpu));
  }
  reset_frames(&core);
  av_frame_free(&hardware); av_frame_free(&software);
  av_buffer_unref(&frames); av_buffer_unref(&device); avformat_free_context(format);
}
