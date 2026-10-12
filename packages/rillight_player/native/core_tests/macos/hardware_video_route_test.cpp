// Requires macOS CoreVideo/VideoToolbox buffers. Exercise the production route
// rather than accepting a portable-mapper-only test as hardware-frame evidence.
#include "../core_implementation.h"
#include "../color_pipeline_fixtures.h"

int main() {
  AVBufferRef* device = nullptr;
  assert(av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                               nullptr, nullptr, 0) == 0);
  AVBufferRef* frames = av_hwframe_ctx_alloc(device);
  assert(frames);
  auto* pool = reinterpret_cast<AVHWFramesContext*>(frames->data);
  pool->format = AV_PIX_FMT_VIDEOTOOLBOX;
  pool->sw_format = AV_PIX_FMT_P010LE;
  pool->width = 64; pool->height = 48;
  assert(av_hwframe_ctx_init(frames) == 0);
  for (int route : {0, 1, 2}) for (bool dovi : {false, true}) {
    RillightCoreImpl core(RillightCoreIo{});
    core.state = RILLIGHT_CORE_OPENING;
    core.macos_edr = true;
    core.gpu_video = route != 0;
    core.video_index = 0;
    core.session = core.timeline = 1;
    AVFormatContext* format = avformat_alloc_context();
    assert(format);
    auto* stream = avformat_new_stream(format, nullptr);
    assert(stream);
    stream->time_base = {1, 25};
    stream->codecpar->codec_type = AVMEDIA_TYPE_VIDEO;
    stream->codecpar->codec_id = AV_CODEC_ID_HEVC;
    if (dovi) stream->codecpar->codec_tag = MKTAG('d','v','h','e');
    AVFrame* source = Picture(AV_PIX_FMT_P010LE, 512);
    if (dovi) Metadata(source);
    source->pts = source->best_effort_timestamp = 0;
    AVFrame* hardware = av_frame_alloc();
    assert(hardware && av_hwframe_get_buffer(frames, hardware, 0) == 0);
    assert(av_hwframe_transfer_data(hardware, source, 0) == 0);
    assert(av_frame_copy_props(hardware, source) == 0);
    VideoScale scale;
    scale.hardware_color_failed = route == 2;
    assert(convert_video_frame(&core, format, hardware, 0, RILLIGHT_CORE_HW_VIDEOTOOLBOX,
        &scale, &core.subtitle_cues, &core.ass, 1, 1, &core.subtitle_mutex) == 0);
    assert(!scale.downloaded && !scale.download_context);
    assert(core.video_processing.summary.find(route == 1 ? "color=cvmetal-direct-linear" : "color=mapped+metal-linear") == 0);
    auto* output = rillight_core_take_frame(reinterpret_cast<RillightCore*>(&core),
                                           RILLIGHT_CORE_VIDEO_RGBA);
    assert(output);
    if (route == 1) {
      assert(output->type == RILLIGHT_CORE_VIDEO_MACOS_LINEAR && !output->data);
      assert(rillight_core_frame_macos_buffer(output));
      assert(output->data_size > 0);
    } else {
    assert(output->type == RILLIGHT_CORE_VIDEO_RGBA16F);
    std::vector<uint16_t> reference(static_cast<size_t>(output->width) * output->height * 4);
    PortableColorPipeline cpu;
    assert(cpu.RenderLinearHalf(source, output->width, output->height, dovi,
                                reference.data(), output->width * 8));
    for (int y = 0; y < output->height; ++y)
      assert(std::memcmp(output->data + y * output->stride,
          reference.data() + static_cast<size_t>(y) * output->width * 4,
          output->width * 8) == 0);
    }
    rillight_core_release_frame(output);
    reset_frames(&core);
    if (dovi) {
      av_frame_remove_side_data(hardware, AV_FRAME_DATA_DOVI_METADATA);
      assert(convert_video_frame(&core, format, hardware, 0, RILLIGHT_CORE_HW_VIDEOTOOLBOX,
          &scale, &core.subtitle_cues, &core.ass, 1, 1, &core.subtitle_mutex) ==
          RILLIGHT_CORE_ERROR_UNSUPPORTED_DOVI);
    }
    av_frame_free(&hardware); av_frame_free(&source);
    avformat_free_context(format);
  }
  av_buffer_unref(&frames); av_buffer_unref(&device);
  std::puts("VideoToolbox mapped HDR/Dolby routes preserve FP16 and RPU validation");
}
