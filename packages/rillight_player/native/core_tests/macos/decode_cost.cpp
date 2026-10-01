extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
}

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <vector>

namespace {
int64_t Us(std::chrono::steady_clock::time_point started) {
  return std::chrono::duration_cast<std::chrono::microseconds>(
      std::chrono::steady_clock::now() - started).count();
}

int Median(std::vector<int64_t> values) {
  if (values.empty()) return -1;
  std::sort(values.begin(), values.end());
  return static_cast<int>(values[values.size() / 2]);
}

AVPixelFormat Choose(AVCodecContext*, const AVPixelFormat* formats) {
  for (const AVPixelFormat* format = formats; *format != AV_PIX_FMT_NONE; ++format) {
    if (*format == AV_PIX_FMT_VIDEOTOOLBOX) return *format;
  }
  return formats[0];
}
}

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: decode_cost <file>\n");
    return 1;
  }
  AVFormatContext* format = nullptr;
  if (avformat_open_input(&format, argv[1], nullptr, nullptr) < 0 ||
      avformat_find_stream_info(format, nullptr) < 0) {
    std::printf("CASE decode ok=0 open=1\n");
    return 2;
  }
  const int index = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
  if (index < 0) return 3;
  const AVCodec* codec = avcodec_find_decoder(format->streams[index]->codecpar->codec_id);
  AVCodecContext* context = avcodec_alloc_context3(codec);
  avcodec_parameters_to_context(context, format->streams[index]->codecpar);
  AVBufferRef* device = nullptr;
  const int device_error = av_hwdevice_ctx_create(
      &device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nullptr, nullptr, 0);
  if (device_error < 0) {
    std::printf("CASE decode ok=0 device=%d\n", device_error);
    return 4;
  }
  context->hw_device_ctx = av_buffer_ref(device);
  context->get_format = Choose;
  if (avcodec_open2(context, codec, nullptr) < 0) {
    std::printf("CASE decode ok=0 open_codec=1\n");
    return 5;
  }
  AVPacket* packet = av_packet_alloc();
  AVFrame* decoded = av_frame_alloc();
  AVFrame* downloaded = av_frame_alloc();
  SwsContext* scaler = nullptr;
  std::vector<int64_t> transfer_us;
  std::vector<int64_t> scale_us;
  int frames = 0;
  int hardware = 0;
  while (frames < 40 && av_read_frame(format, packet) >= 0) {
    if (packet->stream_index != index) {
      av_packet_unref(packet);
      continue;
    }
    if (avcodec_send_packet(context, packet) < 0) {
      av_packet_unref(packet);
      continue;
    }
    av_packet_unref(packet);
    while (avcodec_receive_frame(context, decoded) >= 0 && frames < 40) {
      AVFrame* picture = decoded;
      int64_t transferred = 0;
      if (decoded->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        hardware = 1;
        const auto started = std::chrono::steady_clock::now();
        const int moved = av_hwframe_transfer_data(downloaded, decoded, 0);
        transferred = Us(started);
        if (moved < 0) {
          std::printf("CASE decode ok=0 transfer=%d\n", moved);
          return 6;
        }
        picture = downloaded;
      }
      if (!scaler) {
        scaler = sws_getContext(picture->width, picture->height,
                                static_cast<AVPixelFormat>(picture->format),
                                picture->width, picture->height, AV_PIX_FMT_RGBA,
                                SWS_BILINEAR, nullptr, nullptr, nullptr);
      }
      const int rgba_stride = picture->width * 4;
      std::vector<uint8_t> rgba(static_cast<size_t>(rgba_stride) * picture->height);
      uint8_t* planes[] = {rgba.data()};
      int strides[] = {rgba_stride};
      const auto started = std::chrono::steady_clock::now();
      sws_scale(scaler, picture->data, picture->linesize, 0, picture->height, planes, strides);
      const int64_t scaled = Us(started);
      if (frames >= 4) {
        transfer_us.push_back(transferred);
        scale_us.push_back(scaled);
      }
      ++frames;
      av_frame_unref(decoded);
    }
  }
  std::printf("CASE decode ok=%d frames=%d hardware=%d %dx%d transfer_median_us=%d scale_median_us=%d transfer_max_us=%d scale_max_us=%d\n",
              frames >= 20, frames, hardware,
              context->width, context->height,
              Median(transfer_us), Median(scale_us),
              transfer_us.empty() ? -1 : static_cast<int>(*std::max_element(transfer_us.begin(), transfer_us.end())),
              scale_us.empty() ? -1 : static_cast<int>(*std::max_element(scale_us.begin(), scale_us.end())));
  sws_freeContext(scaler);
  av_frame_free(&downloaded);
  av_frame_free(&decoded);
  av_packet_free(&packet);
  avcodec_free_context(&context);
  av_buffer_unref(&device);
  avformat_close_input(&format);
  return frames >= 20 ? 0 : 7;
}
