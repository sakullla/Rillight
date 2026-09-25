#include "video_surface.h"

#include <Windows.h>

#include <algorithm>
#include <chrono>
#include <cwchar>
#include <stdexcept>
#include <vector>

#include "pixel_present.h"

VideoSurface::VideoSurface(RillightCore* core, std::shared_ptr<CoreApi> api,
                           flutter::TextureRegistrar* textures)
    : core_(core), api_(std::move(api)), textures_(textures) {
  texture_ = std::make_unique<flutter::TextureVariant>(
      // Flutter 3.47 Impeller could not import our independent D3D11 shared
      // texture in a real window. Pixel buffers keep the output path stable;
      // the core may still use a hardware decoder before RGBA conversion.
      flutter::PixelBufferTexture(
          [this](size_t, size_t) { return Obtain(); }));
  texture_id_ = textures_->RegisterTexture(texture_.get());
  if (texture_id_ < 0)
    throw std::runtime_error("Flutter texture registration failed");
}

VideoSurface::~VideoSurface() {
  stopped_ = true;
  if (worker_.joinable()) worker_.join();
  if (audio_) audio_->Stop();
}

void VideoSurface::Start(std::function<void(std::string)> ready) {
  worker_ = std::thread([this, ready = std::move(ready)]() mutable {
    Run(std::move(ready));
  });
}

void VideoSurface::Resize(int width, int height) {
  std::lock_guard lock(mutex_);
  requested_width_ = std::clamp(width, 1, 4096);
  requested_height_ = std::clamp(height, 1, 2304);
}

std::string VideoSurface::error() const {
  std::lock_guard lock(mutex_);
  return error_;
}

std::string VideoSurface::audio_warning() const {
  std::lock_guard lock(mutex_);
  return audio_ ? audio_->error() : std::string();
}

void VideoSurface::SetError(std::string error) {
  std::lock_guard lock(mutex_);
  error_ = std::move(error);
}

const FlutterDesktopPixelBuffer* VideoSurface::Obtain() {
  std::lock_guard lock(mutex_);
  if (stopped_ || !latest_ || tickets_->load() >= 8) return nullptr;
  RillightCoreSnapshot state{};
  state.struct_size = sizeof(state);
  if (api_->snapshot(core_, &state) != 0 ||
      latest_->session != state.session_id ||
      latest_->timeline != state.timeline_version)
    return nullptr;
  auto* ticket = new Ticket();
  ticket->frame = latest_;
  ticket->count = tickets_;
  ++*tickets_;
  auto& descriptor = ticket->descriptor;
  descriptor.buffer = ticket->frame->rgba.data();
  descriptor.width = ticket->frame->width;
  descriptor.height = ticket->frame->height;
  descriptor.release_context = ticket;
  descriptor.release_callback = [](void* context) {
    auto* ticket = static_cast<Ticket*>(context);
    --*ticket->count;
    delete ticket;
  };
  return &descriptor;
}

void VideoSurface::Stop(std::function<void()> done) {
  {
    std::lock_guard lock(mutex_);
    stop_callbacks_.push_back(std::move(done));
    if (stop_started_) return;
    stop_started_ = true;
    stopped_ = true;
  }
  auto self = shared_from_this();
  textures_->UnregisterTexture(texture_id_, [self] {
    if (self->worker_.joinable()) self->worker_.join();
    if (self->audio_) self->audio_->Stop();
    std::vector<std::function<void()>> callbacks;
    {
      std::lock_guard lock(self->mutex_);
      self->latest_.reset();
      callbacks.swap(self->stop_callbacks_);
    }
    for (auto& callback : callbacks) callback();
  });
}

void VideoSurface::Initialize() {
#if defined(_DEBUG)
  wchar_t delay[16]{};
  if (GetEnvironmentVariableW(L"RILLIGHT_TEST_SURFACE_DELAY_MS", delay,
                              static_cast<DWORD>(sizeof(delay) / sizeof(delay[0]))) > 0) {
    const int milliseconds = static_cast<int>(
        std::clamp(std::wcstol(delay, nullptr, 10), 0L, 2000L));
    std::this_thread::sleep_for(std::chrono::milliseconds(milliseconds));
  }
#endif
  audio_ = std::make_unique<AudioOutput>(core_, api_);
  audio_->Start();
}

bool VideoSurface::Publish(const RillightCoreFrame& source, int width,
                           int height, uint64_t session, uint64_t timeline,
                           bool decoded) {
  auto pixels = rillight_windows::Present(source, width, height);
  if (pixels.width == 1 && pixels.height == 1 &&
      (width > 1 || height > 1)) {
    throw std::runtime_error("Invalid decoded video frame");
  }
  auto frame = std::make_shared<Frame>();
  frame->width = pixels.width;
  frame->height = pixels.height;
  frame->session = session;
  frame->timeline = timeline;
  frame->rgba = std::move(pixels.bgra);
  for (size_t offset = 0; offset < frame->rgba.size(); offset += 4) {
    std::swap(frame->rgba[offset], frame->rgba[offset + 2]);
  }
  if (stopped_) return false;
  {
    std::lock_guard lock(mutex_);
    RillightCoreSnapshot state{};
    state.struct_size = sizeof(state);
    if (stopped_ || api_->snapshot(core_, &state) != 0 ||
        state.session_id != session || state.timeline_version != timeline)
      return false;
    latest_ = std::move(frame);
    if (decoded) ++frames_;
  }
  textures_->MarkTextureFrameAvailable(texture_id_);
  return true;
}

void VideoSurface::Run(std::function<void(std::string)> ready) {
  bool announced = false;
  RillightCoreFrame* pending = nullptr;
  std::vector<uint8_t> previous_bytes;
  RillightCoreFrame previous{};
  uint64_t session = 0;
  uint64_t timeline = 0;
  int displayed_width = 0;
  int displayed_height = 0;
  bool drained = false;
  try {
    Initialize();
    announced = true;
    ready("");
    while (!stopped_) {
      RillightCoreSnapshot state{};
      state.struct_size = sizeof(state);
      if (api_->snapshot(core_, &state) != 0)
        throw std::runtime_error("Rillight core snapshot failed");
      if (state.session_id != session || state.timeline_version != timeline) {
        if (pending) api_->release_frame(pending);
        pending = nullptr;
        previous_bytes.clear();
        previous = {};
        session = state.session_id;
        timeline = state.timeline_version;
        drained = false;
        displayed_width = displayed_height = 0;
        int blank_width;
        int blank_height;
        {
          std::lock_guard lock(mutex_);
          latest_.reset();
          blank_width = requested_width_;
          blank_height = requested_height_;
        }
        if (session != 0) {
          uint8_t black[] = {0, 0, 0, 255};
          RillightCoreFrame blank{};
          blank.type = RILLIGHT_CORE_VIDEO_RGBA;
          blank.width = blank.height = 1;
          blank.stride = blank.data_size = 4;
          blank.data = black;
          if (Publish(blank, blank_width, blank_height, session, timeline,
                      false)) {
            displayed_width = blank_width;
            displayed_height = blank_height;
          }
        }
      }
      int width;
      int height;
      {
        std::lock_guard lock(mutex_);
        width = requested_width_;
        height = requested_height_;
      }
      if (!pending) pending = api_->take_frame(core_, RILLIGHT_CORE_VIDEO_RGBA);
      if (pending) {
        if (pending->session_id != session ||
            pending->timeline_version != timeline) {
          api_->release_frame(pending);
          pending = nullptr;
        } else if (pending->pts_us < 0 ||
                   pending->pts_us <= state.position_us + 33000 ||
                   state.state == RILLIGHT_CORE_READY) {
          const bool too_late = state.state == RILLIGHT_CORE_PLAYING &&
                                pending->pts_us >= 0 &&
                                pending->pts_us + 250000 < state.position_us;
          if (!too_late) {
            if (Publish(*pending, width, height, session, timeline)) {
              displayed_width = width;
              displayed_height = height;
              if (pending->data_size > 0 &&
                  pending->data_size <= 64 * 1024 * 1024) {
                previous_bytes.assign(pending->data,
                                      pending->data + pending->data_size);
                previous = *pending;
                previous.data = previous_bytes.data();
              }
            }
          }
          api_->release_frame(pending);
          pending = nullptr;
        }
      }
      if (!previous_bytes.empty() &&
          (width != displayed_width || height != displayed_height)) {
        previous.data = previous_bytes.data();
        if (Publish(previous, width, height, session, timeline)) {
          displayed_width = width;
          displayed_height = height;
        }
      }
      if (!drained && state.source_eof && !pending &&
          state.queued_video_frames == 0 && state.queued_audio_frames == 0 &&
          audio_ && audio_->Empty()) {
        drained = api_->report_output_drained(core_, session, timeline) == 0;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
  } catch (const std::exception& exception) {
    SetError(exception.what());
    if (!announced) ready(exception.what());
  }
  if (pending) api_->release_frame(pending);
  if (audio_) audio_->Stop();
}
