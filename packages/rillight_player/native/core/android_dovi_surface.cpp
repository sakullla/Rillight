#include "android_dovi_surface.h"

#include <android/hardware_buffer.h>
#include <media/NdkImageReader.h>
#include <chrono>
#include <dlfcn.h>
#include <thread>
#include <limits>

extern "C" {
#include <libavcodec/mediacodec.h>
#include <libavutil/frame.h>
#include <libavutil/mathematics.h>
}

namespace {
// API 26 entrypoints are optional: the ordinary app still loads on API 24.
struct ImageApi {
  using New = media_status_t (*)(int32_t, int32_t, int32_t, uint64_t, int32_t, AImageReader**);
  using Buffer = media_status_t (*)(const AImage*, AHardwareBuffer**);
  void* library = dlopen("libmediandk.so", RTLD_NOW | RTLD_LOCAL);
  New create = library ? reinterpret_cast<New>(dlsym(library, "AImageReader_newWithUsage")) : nullptr;
  Buffer buffer = library ? reinterpret_cast<Buffer>(dlsym(library, "AImage_getHardwareBuffer")) : nullptr;
  // Retain the module for the process lifetime, including late frame releases.
};
ImageApi& Api() { static ImageApi api; return api; }
using Owner = std::shared_ptr<AndroidDoviSurface>;
}

struct AndroidDoviSurface::Impl {
  AImageReader* reader = nullptr;
  ANativeWindow* window = nullptr;
  AImage* image = nullptr;
  const void* last_buffer = nullptr;
  int64_t last_pts = AV_NOPTS_VALUE;
  AVRational time_base{};
  ~Impl() {
    if (image) AImage_delete(image);
    if (reader) AImageReader_delete(reader);
  }
};

AndroidDoviSurface::AndroidDoviSurface() : impl_(std::make_unique<Impl>()) {}
AndroidDoviSurface::~AndroidDoviSurface() = default;

std::shared_ptr<AndroidDoviSurface> AndroidDoviSurface::Create(
    int width, int height, int time_num, int time_den) {
  auto& api = Api();
  if (!api.create || !api.buffer || width <= 0 || height <= 0 ||
      time_num <= 0 || time_den <= 0) return {};
  auto result = std::shared_ptr<AndroidDoviSurface>(new AndroidDoviSurface());
  auto& state = *result->impl_;
  // One acquired image also works on codecs with a small gralloc buffer pool.
  if (api.create(width, height, AIMAGE_FORMAT_PRIVATE,
                 AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE, 1, &state.reader) != AMEDIA_OK ||
      AImageReader_getWindow(state.reader, &state.window) != AMEDIA_OK) return {};
  state.time_base = {time_num, time_den};
  return result;
}

ANativeWindow* AndroidDoviSurface::Window() const { return impl_->window; }

bool AndroidDoviSurface::Attach(AVFrame* frame, const Owner& owner) {
  if (!frame || frame->opaque_ref) return false;
  auto* retained = new (std::nothrow) Owner(owner);
  if (!retained) return false;
  frame->opaque_ref = av_buffer_create(reinterpret_cast<uint8_t*>(retained), sizeof(Owner),
      [](void*, uint8_t* data) { delete reinterpret_cast<Owner*>(data); }, nullptr, 0);
  if (!frame->opaque_ref) delete retained;
  return frame->opaque_ref != nullptr;
}

AndroidDoviSurface* AndroidDoviSurface::From(const AVFrame* frame) {
  return frame && frame->opaque_ref && frame->opaque_ref->size == sizeof(Owner)
      ? reinterpret_cast<const Owner*>(frame->opaque_ref->data)->get() : nullptr;
}

AHardwareBuffer* AndroidDoviSurface::Acquire(const AVFrame* frame) {
  auto& state = *impl_;
  if (!frame || frame->format != AV_PIX_FMT_MEDIACODEC || !frame->data[3] ||
      frame->pts == AV_NOPTS_VALUE) return nullptr;
  const int64_t pts_us = av_rescale_q(frame->pts, state.time_base, AVRational{1, 1000000});
  if (pts_us > std::numeric_limits<int64_t>::max() / 1000 ||
      pts_us < std::numeric_limits<int64_t>::min() / 1000) return nullptr;
  // MediaCodec rounds packet timestamps to microseconds before queuing them.
  // Comparing unrounded nanoseconds would reject valid 23.976/29.97 fps frames.
  const int64_t expected = pts_us * 1000;
  if (state.last_buffer != frame->data[3] || state.last_pts != frame->pts) {
    if (state.image) AImage_delete(state.image);
    state.image = nullptr;
    state.last_buffer = nullptr;
    state.last_pts = AV_NOPTS_VALUE;
    if (av_mediacodec_release_buffer(reinterpret_cast<AVMediaCodecBuffer*>(frame->data[3]), 1) < 0)
      return nullptr;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(250);
    while (std::chrono::steady_clock::now() < deadline) {
      const auto status = AImageReader_acquireNextImage(state.reader, &state.image);
      if (status == AMEDIA_OK) {
        int64_t timestamp = 0;
        if (AImage_getTimestamp(state.image, &timestamp) != AMEDIA_OK) return nullptr;
        if (timestamp == expected) break;
        AImage_delete(state.image); state.image = nullptr;
        if (timestamp > expected) return nullptr;
        continue; // Retire a delayed image from a preceding timed-out render.
      }
      if (status != AMEDIA_IMGREADER_NO_BUFFER_AVAILABLE) return nullptr;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (!state.image) return nullptr;
    // Identity is only used for a subtitle redraw of the same retained frame.
    // Owning an AVFrame here would cycle through the codec's device reference.
    state.last_buffer = frame->data[3];
    state.last_pts = frame->pts;
  }
  AHardwareBuffer* buffer = nullptr;
  return Api().buffer(state.image, &buffer) == AMEDIA_OK ? buffer : nullptr;
}
