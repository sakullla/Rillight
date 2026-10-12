#pragma once

// Private shared session model. Never include from a platform adapter.
#include "rillight_core.h"
#include "audio_contract.h"
#include "audio_passthrough.h"
#include "bitmap_subtitle.h"
#include "dts_packet_recovery.h"
#include "video_buffer_pool.h"
#include "video_frame_cost.h"
#include "video_processing_diagnostics.h"
#include "dovi_profile.h"
#include "dovi_enhancement.h"
#include "h264_access_unit.h"
#include "portable_color_pipeline.h"
#include "android_dovi_surface.h"
#include "android_tunnel.h"
#if defined(__ANDROID__)
#include "android_color_pipeline.h"
#endif
#if defined(_WIN32)
#include "windows_color_pipeline.h"
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#endif

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cctype>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>
#if defined(__ANDROID__)
#include <unistd.h>
#include <android/native_window.h>
#endif

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/aes.h>
#include <libavutil/channel_layout.h>
#include <libavutil/cpu.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/hwcontext.h>
#if defined(_WIN32)
#include <libavutil/hwcontext_d3d11va.h>
#endif
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libavutil/opt.h>
#if defined(__ANDROID__)
#include <libavcodec/mediacodec.h>
#include <libavutil/hwcontext_mediacodec.h>
#endif
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#if RILLIGHT_HAVE_LIBASS
#include <ass/ass.h>
#endif
}
#include "dovi_color_metadata.h"

int rillight_dovi_base_rejected(int profile, int compatibility);
void tonemap_rgba(uint8_t *data, int stride, int width, int height,
                  int transfer);

namespace rillight::core {
// Every proxy read crosses a Dart isolate boundary. Larger reads cut the
// per-round-trip cost of demuxer probing through the loopback transport.
constexpr int kIoBufferSize = 262144;
constexpr size_t kMaxVideoFrames = 3;
constexpr size_t kMaxAudioFrames = 16;
constexpr size_t kMaxVideoBytes = 128u * 1024u * 1024u;
constexpr size_t kMaxAudioBytes = 4u * 1024u * 1024u;
#if RILLIGHT_HAVE_LIBASS
constexpr size_t kMaxExternalSubtitleBytes = 4u * 1024u * 1024u;
constexpr size_t kMaxExternalSubtitleTotalBytes = 16u * 1024u * 1024u;
constexpr size_t kMaxExternalSubtitleTracks = 16;
constexpr int kExternalSubtitleStreamBase = 1000000;
#endif
using Clock = std::chrono::steady_clock;
}  // namespace rillight::core
