#pragma once

#include <algorithm>
#include <cstdint>
#include <vector>

extern "C" {
#include <libavutil/frame.h>
}

namespace rillight_color {
// ETSI GS CCM 001 Annex B.3: vertical first, then the B.2 horizontal filter.
// Pixel replication handles boundaries. Work on EL codes, before NLQ.
inline AVFrame* UpsampleFel(const AVFrame* source, int width, int height) {
  if (!source || source->width <= 0 || source->height <= 0 ||
      width != source->width * 2 || height != source->height * 2 ||
      source->format != AV_PIX_FMT_YUV420P10LE) return nullptr;
  auto* result = av_frame_alloc();
  if (!result) return nullptr;
  result->format = source->format;
  result->width = width;
  result->height = height;
  if (av_frame_copy_props(result, source) < 0 || av_frame_get_buffer(result, 32) < 0) {
    av_frame_free(&result);
    return nullptr;
  }
  constexpr int horizontal[8] = {22, 94, -524, 2456, 2456, -524, 94, 22};
  for (int c = 0; c < 3; ++c) {
    const int input_width = c ? (source->width + 1) / 2 : source->width;
    const int input_height = c ? (source->height + 1) / 2 : source->height;
    const int output_width = c ? (width + 1) / 2 : width;
    const int output_height = c ? (height + 1) / 2 : height;
    if (!source->data[c] || source->linesize[c] < input_width * 2) {
      av_frame_free(&result);
      return nullptr;
    }
    std::vector<uint16_t> vertical(static_cast<size_t>(input_width) * output_height);
    const auto sample = [&](int x, int y) {
      const auto* row = reinterpret_cast<const uint16_t*>(source->data[c] +
          std::clamp(y, 0, input_height - 1) * source->linesize[c]);
      return static_cast<int>(row[x]);
    };
    for (int y = 0; y < output_height; ++y) {
      const int n = y / 2;
      for (int x = 0; x < input_width; ++x) {
        int value;
        if (c) {
          value = y & 1 ? (192 * sample(x, n) + 64 * sample(x, n + 1) + 128) >> 8
                        : (64 * sample(x, n - 1) + 192 * sample(x, n) + 128) >> 8;
        } else {
          value = y & 1 ? (-9 * sample(x, n - 1) + 111 * sample(x, n) +
                           29 * sample(x, n + 1) - 3 * sample(x, n + 2) + 64) >> 7
                        : (-3 * sample(x, n - 2) + 29 * sample(x, n - 1) +
                           111 * sample(x, n) - 9 * sample(x, n + 1) + 64) >> 7;
        }
        vertical[static_cast<size_t>(y) * input_width + x] =
            static_cast<uint16_t>(std::clamp(value, 0, 65535));
      }
    }
    for (int y = 0; y < output_height; ++y) {
      auto* row = reinterpret_cast<uint16_t*>(result->data[c] + y * result->linesize[c]);
      const auto* input = vertical.data() + static_cast<size_t>(y) * input_width;
      for (int x = 0; x < output_width; ++x) {
        const int n = x / 2;
        if (!(x & 1)) row[x] = input[n];
        else {
          int value = 2048;
          for (int tap = 0; tap < 8; ++tap)
            value += horizontal[tap] * input[std::clamp(n - 3 + tap, 0, input_width - 1)];
          row[x] = static_cast<uint16_t>(std::clamp(value >> 12, 0, 65535));
        }
      }
    }
  }
  return result;
}
}  // namespace rillight_color
