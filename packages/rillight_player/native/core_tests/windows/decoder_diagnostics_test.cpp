// Exercise format renegotiation and real D3D11 frame routing without requiring
// a particular hardware video codec. --benchmark measures synthetic conversion.
#include "../core_implementation.h"
#include "../color_pipeline_fixtures.h"
#include <cassert>
#include <initguid.h>
#include <dxva.h>
#include <wrl/client.h>
#include "sdr_video_route_test.h"

void CheckProfile5SubtitleRoute() {
  RillightCoreImpl core(RillightCoreIo{});
  core.state = RILLIGHT_CORE_OPENING;
  core.gpu_video = true;
  core.video_index = 0;
  core.subtitle_index = 1;
  core.session = core.timeline = 1;
  AVFormatContext* format = avformat_alloc_context();
  assert(format);
  auto* stream = avformat_new_stream(format, nullptr);
  assert(stream);
  stream->time_base = {1, 25};
  stream->codecpar->codec_type = AVMEDIA_TYPE_VIDEO;
  stream->codecpar->codec_id = AV_CODEC_ID_HEVC;
  stream->codecpar->codec_tag = MKTAG('d','v','h','e');
  AVFrame* frame = Picture(AV_PIX_FMT_P010LE, 512);
  Metadata(frame);
  frame->pts = frame->best_effort_timestamp = 0;
  VideoScale scale;
  assert(convert_video_frame(&core, format, frame, 0, RILLIGHT_CORE_HW_NONE,
      &scale, &core.subtitle_cues, &core.ass, 1, 1, &core.subtitle_mutex) == 0);
  assert(core.video.size() == 1);
  assert(core.video.front()->type == RILLIGHT_CORE_VIDEO_D3D11);
  assert(core.video_processing.summary.find("color=gpu-sdr") == 0);
  auto* ready = rillight_core_take_frame(reinterpret_cast<RillightCore*>(&core),
                                       RILLIGHT_CORE_VIDEO_D3D11);
  assert(ready && ready->type == RILLIGHT_CORE_VIDEO_D3D11);
  rillight_core_release_frame(ready);
  reset_frames(&core);
  assert(core.video_processing.summary.empty());
  // Missing RPU must remain a hard error for Profile 5 even after refactoring.
  av_frame_remove_side_data(frame, AV_FRAME_DATA_DOVI_METADATA);
  assert(convert_video_frame(&core, format, frame, 0, RILLIGHT_CORE_HW_NONE,
      &scale, &core.subtitle_cues, &core.ass, 1, 1, &core.subtitle_mutex) ==
      RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI);
  av_frame_free(&frame);
  avformat_free_context(format);
}

// Exercise the core route, not just WindowsColorPipeline: platform guards can
// otherwise silently turn hardware textures into download + upload traffic.
void CheckHardwareColorRoute(bool dovi, bool hdr, bool download = false,
                             int width = 64, int height = 48,
                             bool benchmark = false, int mmr_order = 0) {
  AVBufferRef* device = nullptr;
  assert(av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_D3D11VA,
                               nullptr, nullptr, 0) == 0);
  AVBufferRef* frames = av_hwframe_ctx_alloc(device);
  assert(frames);
  auto* pool = reinterpret_cast<AVHWFramesContext*>(frames->data);
  pool->format = AV_PIX_FMT_D3D11;
  pool->sw_format = AV_PIX_FMT_P010LE;
  pool->width = width; pool->height = height; pool->initial_pool_size = 2;
  assert(av_hwframe_ctx_init(frames) == 0);
  AVFrame* software = av_frame_alloc();
  AVFrame* hardware = av_frame_alloc();
  assert(software && hardware);
  software->format = AV_PIX_FMT_P010LE;
  software->width = width; software->height = height;
  software->color_trc = AVCOL_TRC_SMPTE2084;
  software->color_primaries = AVCOL_PRI_BT2020;
  software->colorspace = AVCOL_SPC_BT2020_NCL;
  software->color_range = AVCOL_RANGE_MPEG;
  software->pts = software->best_effort_timestamp = 0;
  assert(av_frame_get_buffer(software, 32) == 0);
  for (int plane = 0; plane < 2; ++plane) {
    for (int y = 0; y < height / (plane + 1); ++y) {
      auto* row = reinterpret_cast<uint16_t*>(
          software->data[plane] + y * software->linesize[plane]);
      for (int x = 0; x < width; ++x)
        row[x] = static_cast<uint16_t>((plane ? 512 : 128 + (x + y) % 640) << 6);
    }
  }
  if (dovi) {
    auto* metadata = Metadata(software);
    if (mmr_order) {
      for (int c = 0; c < 3; ++c) {
        auto& curve = av_dovi_get_mapping(metadata)->curves[c];
        curve.mapping_idc[0] = AV_DOVI_MAPPING_MMR;
        curve.mmr_order[0] = mmr_order;
        curve.mmr_coef[0][0][c] = 1;
      }
    }
  }
  assert(av_hwframe_get_buffer(frames, hardware, 0) == 0);
  assert(av_hwframe_transfer_data(hardware, software, 0) == 0);
  assert(av_frame_copy_props(hardware, software) == 0);
  // Repeated synthetic input has no playback clock; do not benchmark the
  // late-frame discard shortcut once wall time advances past its first PTS.
  if (benchmark) hardware->pts = hardware->best_effort_timestamp = AV_NOPTS_VALUE;

  RillightCoreImpl core(RillightCoreIo{});
  core.state = RILLIGHT_CORE_OPENING;
  core.gpu_video = true; core.hdr_video = hdr;
  core.video_index = 0; core.subtitle_index = 1;
  core.session = core.timeline = 1;
  AVFormatContext* format = avformat_alloc_context();
  assert(format);
  auto* stream = avformat_new_stream(format, nullptr);
  assert(stream);
  stream->time_base = {1, 60};
  stream->codecpar->codec_type = AVMEDIA_TYPE_VIDEO;
  stream->codecpar->codec_id = AV_CODEC_ID_HEVC;
  if (dovi) stream->codecpar->codec_tag = MKTAG('d','v','h','e');
  VideoScale scale;
  // The existing failure latch reproduces the download route for comparison.
  scale.hardware_color_failed = download;
  std::vector<double> samples;
  for (int iteration = 0; iteration < (benchmark ? 110 : 2); ++iteration) {
    const auto start = Clock::now();
    assert(convert_video_frame(&core, format, hardware, 0, RILLIGHT_CORE_HW_D3D11,
        &scale, &core.subtitle_cues, &core.ass, 1, 1, &core.subtitle_mutex) == 0);
    const double ms = std::chrono::duration<double, std::milli>(Clock::now() - start).count();
    assert(core.video.size() == 1);
    assert(core.video.front()->type == RILLIGHT_CORE_VIDEO_D3D11);
    const std::string path = std::string("color=") + (download ? "download+" : "") +
        (hdr ? "gpu-scrgb" : "gpu-sdr");
    assert(core.video_processing.summary.find(path) == 0);
    assert((scale.downloaded != nullptr) == download);
    assert(scale.hardware_color_failed == download);
    auto* ready = rillight_core_take_frame(reinterpret_cast<RillightCore*>(&core),
                                         RILLIGHT_CORE_VIDEO_D3D11);
    assert(ready);
    rillight_core_release_frame(ready);
    if (iteration >= 10) samples.push_back(ms);
  }
  if (benchmark) {
    std::sort(samples.begin(), samples.end());
    std::printf("{\"route\":\"%s\",\"source\":\"%s\",\"mmrOrder\":%d,\"width\":%d,\"height\":%d,"
                "\"samples\":%zu,\"medianMs\":%.3f,\"p95Ms\":%.3f}\n",
                hdr ? "gpu-scrgb" : download ? "download+gpu-sdr" : "gpu-sdr",
                dovi ? "synthetic-RPU" : "HDR10", mmr_order,
                width, height, samples.size(), samples[samples.size()/2],
                samples[samples.size()*95/100]);
  }
  if (dovi) {
    av_frame_remove_side_data(hardware, AV_FRAME_DATA_DOVI_METADATA);
    assert(convert_video_frame(&core, format, hardware, 0, RILLIGHT_CORE_HW_D3D11,
        &scale, &core.subtitle_cues, &core.ass, 1, 1, &core.subtitle_mutex) ==
        RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI);
  }
  reset_frames(&core);
  avformat_free_context(format);
  av_frame_free(&hardware); av_frame_free(&software);
  av_buffer_unref(&frames); av_buffer_unref(&device);
}

int main(int argc, char** argv) {
  VideoProcessingDiagnostics processing;
  processing.Record("swscale", true, 1000);
  processing.NativeSurface();
  assert(processing.summary == "color=mediacodec-surface");
  assert(processing.frames == 0 && processing.elapsed_us == 0);
  processing.Record("swscale", false, 2000);
  assert(processing.summary == "color=swscale convert=2.0ms");
  if (argc == 2 && (std::strcmp(argv[1], "--benchmark-sdr-cpu") == 0 ||
                   std::strcmp(argv[1], "--benchmark-sdr-gpu") == 0)) {
    const bool gpu = std::strcmp(argv[1], "--benchmark-sdr-gpu") == 0;
    for (int width : {1920, 3840})
      CheckHardwareSdrRoute(AV_PIX_FMT_NV12, AVCOL_SPC_BT709, AVCOL_RANGE_MPEG,
          gpu, width, width * 9 / 16, true);
    return 0;
  }
  if (argc == 2 && std::strcmp(argv[1], "--benchmark-hdr") == 0) {
    CheckHardwareColorRoute(false, true, false, 3840, 2160, true);
    for (int order : {0, 1, 3})
      CheckHardwareColorRoute(true, true, false, 3840, 2160, true, order);
    return 0;
  }
  if (argc == 2 && std::strcmp(argv[1], "--benchmark") == 0) {
    for (bool dovi : {false, true})
      for (bool download : {true, false})
        CheckHardwareColorRoute(dovi, false, download, 3840, 2160, true);
    return 0;
  }
  // Compare locally declared compatibility GUIDs with the SDK, not another
  // handwritten copy. A typo must not reject a supported presenter's adapter.
  assert(IsEqualGUID(kGuidH264VldNoFgt, DXVA_ModeH264_VLD_NoFGT));
  assert(IsEqualGUID(kGuidHevcVldMain, DXVA_ModeHEVC_VLD_Main));
  assert(IsEqualGUID(kGuidHevcVldMain10, DXVA_ModeHEVC_VLD_Main10));
  assert(IsEqualGUID(kGuidVp9VldProfile0, DXVA_ModeVP9_VLD_Profile0));
  assert(IsEqualGUID(kGuidAv1VldProfile0, DXVA_ModeAV1_VLD_Profile0));
  RillightCoreImpl core(RillightCoreIo{});
  RillightCoreTrack track{};
  track.stream_index = 0;
  core.tracks.push_back(track);
  Decoder decoder;
  decoder.context = avcodec_alloc_context3(nullptr);
  assert(decoder.context);
  decoder.context->thread_count = 4;
  decoder.stream = 0;
  decoder.hardware = RILLIGHT_CORE_HW_D3D11;
  decoder.hw_format = std::make_shared<HardwareFormatSelection>(
      HardwareFormatSelection{AV_PIX_FMT_D3D11, true});
  decoder.context->opaque = decoder.hw_format.get();
  decoder.hardware_diagnostics = decoder.diagnostics =
      "d3d11 adapter 'test' threads=4";
  AVFrame *frame = av_frame_alloc();
  assert(frame);
  const AVPixelFormat hardware[] = {AV_PIX_FMT_D3D11, AV_PIX_FMT_YUV420P,
                                     AV_PIX_FMT_NONE};
  frame->format = choose_hardware_format(decoder.context, hardware);
  update_decode_diagnostics(&core, decoder, frame);
  assert(core.tracks[0].actual_hardware == RILLIGHT_CORE_HW_D3D11);
  assert(core.decode_diagnostics == decoder.hardware_diagnostics);

  // FFmpeg retries get_format without D3D11 when a stream profile is refused.
  const AVPixelFormat software[] = {AV_PIX_FMT_YUV420P, AV_PIX_FMT_NONE};
  frame->format = choose_hardware_format(decoder.context, software);
  assert(frame->format == AV_PIX_FMT_YUV420P);
  update_decode_diagnostics(&core, decoder, frame);
  assert(core.tracks[0].actual_hardware == RILLIGHT_CORE_HW_NONE);
  assert(core.decode_diagnostics.find("software ffmpeg_threads=4;") == 0);
  assert(core.decode_diagnostics.find("hardware format unavailable") != std::string::npos);
  decoder.hw_format->allow_software_fallback = false;
  assert(choose_hardware_format(decoder.context, software) == AV_PIX_FMT_NONE);

  // CPU planes exported by MediaCodec are still hardware-decoded.
  decoder.hardware = RILLIGHT_CORE_HW_MEDIACODEC;
  decoder.hardware_diagnostics = "hardware threads=4";
  av_dict_set(&frame->metadata, "rillight.mediacodec.name", "test", 0);
  update_decode_diagnostics(&core, decoder, frame);
  assert(core.tracks[0].actual_hardware == RILLIGHT_CORE_HW_MEDIACODEC);
  assert(core.decode_diagnostics == "hardware threads=4");
  av_frame_free(&frame);
  avcodec_free_context(&decoder.context);

  // Exercise the attached-device callback contract when this host supports it.
  AVBufferRef *device = nullptr;
  std::string note;
  if (create_attached_d3d11_hwdevice(&device, nullptr, AV_CODEC_ID_H264,
          AV_PROFILE_H264_MAIN, AV_PIX_FMT_YUV420P, &note) >= 0) {
    auto *context = reinterpret_cast<AVHWDeviceContext *>(device->data);
    auto *d3d11 = static_cast<AVD3D11VADeviceContext *>(context->hwctx);
    assert(d3d11->lock && d3d11->unlock);
    d3d11->lock(d3d11->lock_ctx);
    d3d11->lock(d3d11->lock_ctx);
    d3d11->unlock(d3d11->lock_ctx);
    d3d11->unlock(d3d11->lock_ctx);
    av_buffer_unref(&device);
    std::puts("D3D11 recursive locking passed");
    CheckProfile5SubtitleRoute();
    for (auto pixel_format : {AV_PIX_FMT_NV12, AV_PIX_FMT_P010LE})
      for (auto matrix : {AVCOL_SPC_BT709, AVCOL_SPC_SMPTE170M, AVCOL_SPC_BT470BG})
        for (auto range : {AVCOL_RANGE_MPEG, AVCOL_RANGE_JPEG}) {
          CheckHardwareSdrRoute(pixel_format, matrix, range, true);
          CheckHardwareSdrRoute(pixel_format, matrix, range, true, 64, 48, false, false, true);
          CheckHardwareSdrRoute(pixel_format, matrix, range, false);
          CheckHardwareSdrRoute(pixel_format, matrix, range, true, 64, 48, false, true);
        }
    for (bool dovi : {false, true})
      for (bool hdr : {false, true})
        for (bool download : {false, true})
          CheckHardwareColorRoute(dovi, hdr, download);
  } else {
    std::printf("D3D11 device unavailable: %s\n", note.c_str());
  }
  return 0;
}
