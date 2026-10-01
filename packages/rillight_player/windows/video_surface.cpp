#include "video_surface.h"

#include <Windows.h>

#include <algorithm>
#include <chrono>
#include <cwchar>
#include <stdexcept>
#include <vector>

#include "pixel_present.h"

VideoSurface::VideoSurface(RillightCore* core, std::shared_ptr<CoreApi> api,
                           flutter::TextureRegistrar* textures, IDXGIAdapter* adapter, HWND window)
    : core_(core), api_(std::move(api)), textures_(textures) {
  try {
    if (adapter) {
      gpu_presenter_ = std::make_unique<rillight_windows::GpuPresenter>(adapter);
      if (api_->configure_gpu_video(core_, 1) != 0) gpu_presenter_.reset();
    }
  } catch (const std::exception&) {
    gpu_presenter_.reset();
  }
  if (gpu_presenter_ && window) {
    try {
      hdr_host_ = std::make_unique<rillight_windows::HdrHost>(window, gpu_presenter_.get());
      if (api_->configure_hdr_video(core_, 1) != 0) hdr_host_.reset();
    } catch (const std::exception&) { hdr_host_.reset(); }
  }
  if (gpu_presenter_) {
    texture_ = std::make_unique<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
        kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
        [this](size_t, size_t) { return ObtainGpu(); }));
  } else texture_ = std::make_unique<flutter::TextureVariant>(
      // CPU textures remain available when the GPU presenter cannot initialize.
      flutter::PixelBufferTexture(
          [this](size_t, size_t) { return Obtain(); }));
  texture_id_ = textures_->RegisterTexture(texture_.get());
  if (texture_id_ < 0)
    throw std::runtime_error("Flutter texture registration failed");
  api_->set_video_output_size(core_, requested_width_, requested_height_);
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
  api_->set_video_output_size(core_, requested_width_, requested_height_);
}

void VideoSurface::ActivateNativeOverlay() { if (hdr_host_) hdr_host_->Activate(); }
void VideoSurface::UpdateNativeOverlay() { if (hdr_host_) hdr_host_->UpdateWindow(); }
void VideoSurface::HideNativeOverlay() { if (hdr_host_) hdr_host_->Hide(); }
rillight_windows::HdrDisplayInfo VideoSurface::hdr_display() const {
  return hdr_host_ ? hdr_host_->display() : rillight_windows::HdrDisplayInfo{};
}
uint64_t VideoSurface::hdr_source_frames() const { return hdr_host_ ? hdr_host_->hdr_source_frames() : 0; }
rillight_windows::HdrPresentStats VideoSurface::hdr_stats() const {
  return hdr_host_ ? hdr_host_->stats() : rillight_windows::HdrPresentStats{};
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
  ++texture_callbacks_;
  std::lock_guard lock(mutex_);
  if (stopped_ || tickets_->load() >= 8) return nullptr;
  RillightCoreSnapshot state{};
  state.struct_size = sizeof(state);
  if (api_->snapshot(core_, &state) != 0) return nullptr;
  // Select at Flutter's raster deadline, instead of letting two decoder
  // publications in one vsync overwrite a picture that has not been drawn.
  while (!presentation_.empty()) {
    const auto& frame = presentation_.front();
    if (frame->session != state.session_id ||
        frame->timeline != state.timeline_version) {
      presentation_.pop_front();
      continue;
    }
    if (frame->pts_us >= 0 && frame->pts_us > state.position_us + 5000 &&
        latest_ && latest_->decoded && state.state != RILLIGHT_CORE_ENDED)
      break;
    latest_ = std::move(presentation_.front());
    presentation_.pop_front();
    // Preserve consecutive pictures across small vsync jitter. Catch up only
    // when genuinely behind, rather than dropping a frame for a 1 ms wobble.
    if (latest_->pts_us < 0 || latest_->pts_us >= state.position_us - 50000)
      break;
  }
  if (!latest_ || latest_->session != state.session_id ||
      latest_->timeline != state.timeline_version) return nullptr;
  auto* ticket = new Ticket();
  if (latest_->sequence != acquired_sequence_) {
    acquired_sequence_ = latest_->sequence;
    ++acquired_frames_;
  }
  ticket->frame = latest_;
  acquired_timeline_ = latest_->decoded ? latest_->timeline : 0;
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

const FlutterDesktopGpuSurfaceDescriptor* VideoSurface::ObtainGpu() {
  const auto* pixels = Obtain();
  if (!pixels) return nullptr;
  auto* ticket = static_cast<Ticket*>(pixels->release_context);
  auto& descriptor = gpu_descriptor_;
  // ANGLE invokes release_callback before reading visible dimensions. Keep
  // this descriptor outside the retired ticket, unlike the pixel-buffer ABI.
  descriptor.struct_size = sizeof(descriptor);
  descriptor.handle = ticket->frame->gpu->handle;
  descriptor.width = descriptor.visible_width = ticket->frame->width;
  descriptor.height = descriptor.visible_height = ticket->frame->height;
  descriptor.format = kFlutterDesktopPixelFormatBGRA8888;
  descriptor.release_context = ticket;
  descriptor.release_callback = pixels->release_callback;
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
      self->presentation_.clear();
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
  if (hdr_host_) {
    RillightCoreSubtitleOverlay overlay{}; overlay.struct_size = sizeof(overlay);
    api_->frame_subtitle_overlay(&source, &overlay);
    try {
      hdr_host_->Draw(source, api_->frame_d3d11_texture(&source), &overlay, width, height);
    } catch (const rillight_windows::GpuImportUnavailable&) {
      if (source.type != RILLIGHT_CORE_VIDEO_D3D11 || api_->configure_gpu_video(core_, 0) != 0) throw;
      return false;
    }
    std::lock_guard lock(mutex_);
    RillightCoreSnapshot state{}; state.struct_size = sizeof(state);
    if (stopped_ || api_->snapshot(core_, &state) != 0 ||
        state.session_id != session || state.timeline_version != timeline) return false;
    hdr_host_->Commit();
    if (decoded) { ++frames_; ++acquired_frames_; }
    acquired_timeline_ = decoded || source.width > 1 || source.height > 1 ? timeline : 0;
    return true;
  }
  auto frame = std::make_shared<Frame>();
  if (gpu_presenter_) {
    try {
      frame->gpu = gpu_presenter_->Present(source,
          api_->frame_d3d11_texture(&source), width, height);
    } catch (const rillight_windows::GpuImportUnavailable&) {
      // Hybrid-GPU systems may decode and draw on different adapters. Keep
      // the BGRA sink, but obtain CPU frames from the decoder for later uploads.
      if (source.type != RILLIGHT_CORE_VIDEO_D3D11 ||
          api_->configure_gpu_video(core_, 0) != 0) throw;
      return false;
    }
    frame->width = frame->gpu->width;
    frame->height = frame->gpu->height;
  } else {
    auto pixels = rillight_windows::Present(source, width, height);
    if (pixels.width == 1 && pixels.height == 1 && (width > 1 || height > 1))
      throw std::runtime_error("Invalid decoded video frame");
    frame->width = pixels.width;
    frame->height = pixels.height;
    frame->rgba = std::move(pixels.rgba);
  }
  frame->session = session;
  frame->timeline = timeline;
  frame->pts_us = source.pts_us;
  frame->decoded = decoded || source.width > 1 || source.height > 1;
  if (stopped_) return false;
  {
    std::lock_guard lock(mutex_);
    RillightCoreSnapshot state{};
    state.struct_size = sizeof(state);
    if (stopped_ || api_->snapshot(core_, &state) != 0 ||
        state.session_id != session || state.timeline_version != timeline)
      return false;
    if (decoded) ++frames_;
    frame->sequence = frames_;
    if (decoded) {
      presentation_.push_back(std::move(frame));
      // Occlusion must not hold the decoder or grow RGBA memory without bound.
      while (presentation_.size() > 3) presentation_.pop_front();
    } else {
      presentation_.clear();
      latest_ = std::move(frame);
    }
    notified_at_ = std::chrono::steady_clock::now();
  }
  textures_->MarkTextureFrameAvailable(texture_id_);
  return true;
}

void VideoSurface::Run(std::function<void(std::string)> ready) {
  bool announced = false;
  RillightCoreFrame* pending = nullptr;
  RillightCoreFrame* previous = nullptr;
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
        if (previous) api_->release_frame(previous);
        previous = nullptr;
        session = state.session_id;
        timeline = state.timeline_version;
        drained = false;
        displayed_width = displayed_height = 0;
        int blank_width;
        int blank_height;
        {
          std::lock_guard lock(mutex_);
          latest_.reset();
          presentation_.clear();
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
      if (!pending) pending = api_->take_frame(core_, gpu_presenter_
          ? RILLIGHT_CORE_VIDEO_D3D11 : RILLIGHT_CORE_VIDEO_RGBA);
      if (pending) {
        if (pending->session_id != session ||
            pending->timeline_version != timeline) {
          api_->release_frame(pending);
          pending = nullptr;
        } else if (pending->pts_us < 0 ||
                   pending->pts_us <= state.position_us + 10000 ||
                   state.state == RILLIGHT_CORE_READY) {
          // The core already selects the newest due frame and discards older
          // queued pictures. Rejecting its last available frame here can leave
          // the texture frozen indefinitely when HDR conversion runs late.
          if (Publish(*pending, width, height, session, timeline)) {
            displayed_width = width;
            displayed_height = height;
            // Retain the decoded frame for resize instead of copying the
            // full source RGBA buffer again (32 MiB per 4K frame).
            if (previous) api_->release_frame(previous);
            previous = pending;
            pending = nullptr;
          }
          if (pending) api_->release_frame(pending);
          pending = nullptr;
        }
      }
      if (previous &&
          (width != displayed_width || height != displayed_height)) {
        if (Publish(*previous, width, height, session, timeline, false)) {
          displayed_width = width;
          displayed_height = height;
        }
      }
      if (!drained && state.source_eof && !pending &&
          state.queued_video_frames == 0 && state.queued_audio_frames == 0 &&
          audio_ && audio_->Empty()) {
        drained = api_->report_output_drained(core_, session, timeline) == 0;
      }
      bool notify = false;
      {
        std::lock_guard lock(mutex_);
        const auto now = std::chrono::steady_clock::now();
        if (!presentation_.empty() && now - notified_at_ >= std::chrono::milliseconds(8)) {
          notified_at_ = now;
          notify = true;
        }
      }
      // A picture acquired before its PTS remains queued. Request another
      // raster opportunity even if no new frame notification arrives yet.
      if (notify) textures_->MarkTextureFrameAvailable(texture_id_);
      // Keep the presentation deadline close to the media clock. A 5 ms
      // polling interval jitters 60 Hz input across Flutter's vsync boundary,
      // which merges consecutive texture notifications into one displayed
      // frame even when decode and conversion both sustain 60 fps.
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  } catch (const std::exception& exception) {
    SetError(exception.what());
    if (!announced) ready(exception.what());
  }
  if (pending) api_->release_frame(pending);
  if (previous) api_->release_frame(previous);
  if (audio_) audio_->Stop();
}
