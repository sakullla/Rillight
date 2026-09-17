#include "video_surface.h"
#include <dxgi.h>
#include <algorithm>
#include <chrono>
#include <stdexcept>

namespace {
void Check(HRESULT value, const char* operation) {
  if (FAILED(value)) throw std::runtime_error(operation);
}
void* Resolve(void*, const char* name) { return reinterpret_cast<void*>(eglGetProcAddress(name)); }
}

VideoSurface::VideoSurface(mpv_handle* player, flutter::TextureRegistrar* textures)
    : player_(player), textures_(textures) {
  texture_ = std::make_unique<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
      kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle, [this](size_t, size_t) { return Obtain(); }));
  texture_id_ = textures_->RegisterTexture(texture_.get());
  if (texture_id_ < 0) throw std::runtime_error("Flutter texture registration failed");
}
VideoSurface::~VideoSurface() {
  { std::lock_guard<std::mutex> lock(mutex_); stopped_ = true; }
  wake_.notify_all();
  if (worker_.joinable()) worker_.join();
}
void VideoSurface::Start(std::function<void(std::string)> ready) {
  worker_ = std::thread([this, ready] { Run(ready); });
}
void VideoSurface::Resize(int width, int height) {
  { std::lock_guard<std::mutex> lock(mutex_); requested_width_ = std::clamp(width, 1, 7680); requested_height_ = std::clamp(height, 1, 4320); dirty_ = true; }
  wake_.notify_one();
}
void VideoSurface::Update(void* data) {
  auto self = static_cast<VideoSurface*>(data);
  { std::lock_guard<std::mutex> lock(self->mutex_); if (self->stopped_) return; self->dirty_ = true; }
  self->wake_.notify_one();
}
std::string VideoSurface::error() { std::lock_guard<std::mutex> lock(mutex_); return error_; }
const FlutterDesktopGpuSurfaceDescriptor* VideoSurface::Obtain() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopped_ || !latest_ || tickets_->load() >= 8) return nullptr;
  auto ticket = new Ticket();
  ticket->frame = latest_;
  ticket->count = tickets_;
  ++*tickets_;
  // Flutter may read descriptor fields after calling release_callback.
  auto& d = descriptor_;
  d.struct_size = sizeof(d);
  d.handle = ticket->frame->handle;
  d.width = d.visible_width = ticket->frame->width;
  d.height = d.visible_height = ticket->frame->height;
  d.format = kFlutterDesktopPixelFormatBGRA8888;
  d.release_context = ticket;
  d.release_callback = [](void* context) {
    auto ticket = static_cast<Ticket*>(context);
    --*ticket->count;
    // The engine's imported D3D reference keeps the allocation alive. No frame
    // is ever returned to a mutable pool: release only retires this ticket.
    delete ticket;
  };
  return &d;
}
void VideoSurface::Stop(std::function<void()> done) {
  { std::lock_guard<std::mutex> lock(mutex_); stopped_ = true; }
  wake_.notify_one();
  auto self = shared_from_this();
  // Retain callback target until the raster thread has stopped accessing it.
  textures_->UnregisterTexture(texture_id_, [self, done] {
    if (self->worker_.joinable()) self->worker_.join();
    { std::lock_guard<std::mutex> lock(self->mutex_); self->latest_.reset(); }
    done();
  });
}
void VideoSurface::Initialize() {
  auto platformDisplay = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
  if (!platformDisplay) throw std::runtime_error("ANGLE platform display unavailable");
  // A distinct EGL device/display per surface: eglTerminate must never tear
  // down a sibling player's context on ANGLE's cached default display.
  using CreateDevice = EGLDeviceEXT(EGLAPIENTRY*)(EGLint, void*, const EGLAttrib*);
  auto createDevice = reinterpret_cast<CreateDevice>(eglGetProcAddress("eglCreateDeviceANGLE"));
  if (!createDevice) throw std::runtime_error("ANGLE device creation unavailable");
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0};
  Check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 1, D3D11_SDK_VERSION, &device_, nullptr, &device_context_), "D3D11 hardware device creation failed");
  angle_device_ = createDevice(EGL_D3D11_DEVICE_ANGLE, device_.Get(), nullptr);
  if (angle_device_ == EGL_NO_DEVICE_EXT) throw std::runtime_error("ANGLE device creation failed");
  display_ = platformDisplay(EGL_PLATFORM_DEVICE_EXT, angle_device_, nullptr);
  if (!eglInitialize(display_, nullptr, nullptr)) throw std::runtime_error("ANGLE initialization failed");
  const EGLint config[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLint count = 0;
  if (!eglChooseConfig(display_, config, &config_, 1, &count) || count == 0) throw std::runtime_error("ANGLE framebuffer configuration failed");
  const EGLint context[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  context_ = eglCreateContext(display_, config_, EGL_NO_CONTEXT, context);
  if (context_ == EGL_NO_CONTEXT) throw std::runtime_error("ANGLE context creation failed");
  CreateTarget(1280, 720);
  mpv_opengl_init_params gl{Resolve, nullptr};
  int advanced = 1;
  mpv_render_param params[] = {{MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_OPENGL)}, {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl}, {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced}, {MPV_RENDER_PARAM_INVALID, nullptr}};
  const auto result = mpv_render_context_create(&render_, player_, params);
  if (result < 0) throw std::runtime_error(mpv_error_string(result));
  mpv_render_context_set_update_callback(render_, Update, this);
}
void VideoSurface::CreateTarget(int width, int height) {
  eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  if (surface_ != EGL_NO_SURFACE) eglDestroySurface(display_, surface_);
  target_.Reset();
  D3D11_TEXTURE2D_DESC description{};
  description.Width = width; description.Height = height;
  description.MipLevels = description.ArraySize = description.SampleDesc.Count = 1;
  description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  description.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  description.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  Check(device_->CreateTexture2D(&description, nullptr, &target_), "D3D render target allocation failed");
  Microsoft::WRL::ComPtr<IDXGIResource> resource;
  Check(target_.As(&resource), "D3D render target resource unavailable");
  HANDLE handle = nullptr;
  Check(resource->GetSharedHandle(&handle), "D3D shared handle failed");
  const EGLint attributes[] = {EGL_WIDTH, width, EGL_HEIGHT, height, EGL_NONE};
  surface_ = eglCreatePbufferFromClientBuffer(display_, EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE, handle, config_, attributes);
  if (surface_ == EGL_NO_SURFACE || !eglMakeCurrent(display_, surface_, surface_, context_)) throw std::runtime_error("ANGLE render target bind failed");
  width_ = width; height_ = height;
}
void VideoSurface::Render() {
  auto frame = std::make_shared<Frame>();
  frame->width = width_; frame->height = height_;
  mpv_opengl_fbo fbo{0, width_, height_, 0};
  // The pbuffer is imported as a texture, not presented as a GL window.
  // control.dart enforces video-timing-offset=0 for the nonblocking renderer.
  int flip = 0, block = 0;
  mpv_render_frame_info info{};
  mpv_render_context_get_info(render_, {MPV_RENDER_PARAM_NEXT_FRAME_INFO, &info});
  mpv_render_param params[] = {{MPV_RENDER_PARAM_OPENGL_FBO, &fbo}, {MPV_RENDER_PARAM_FLIP_Y, &flip}, {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block}, {MPV_RENDER_PARAM_INVALID, nullptr}};
  if (mpv_render_context_render(render_, params) < 0) throw std::runtime_error("libmpv render failed");
  glFinish(); // Worker only. Raster callback never waits for a GPU.
  D3D11_TEXTURE2D_DESC description;
  target_->GetDesc(&description);
  Check(device_->CreateTexture2D(&description, nullptr, &frame->texture), "D3D snapshot allocation failed");
  Microsoft::WRL::ComPtr<IDXGIResource> resource;
  Check(frame->texture.As(&resource), "D3D snapshot resource unavailable");
  Check(resource->GetSharedHandle(&frame->handle), "D3D snapshot sharing failed");
  D3D11_QUERY_DESC queryDescription{D3D11_QUERY_EVENT, 0};
  Microsoft::WRL::ComPtr<ID3D11Query> query;
  Check(device_->CreateQuery(&queryDescription, &query), "D3D completion query failed");
  device_context_->CopyResource(frame->texture.Get(), target_.Get());
  device_context_->End(query.Get());
  device_context_->Flush();
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (true) {
    const auto result = device_context_->GetData(query.Get(), nullptr, 0, D3D11_ASYNC_GETDATA_DONOTFLUSH);
    if (result == S_OK) break;
    Check(result, "D3D completion failed (device removed)");
    { std::lock_guard<std::mutex> lock(mutex_); if (stopped_) return; }
    if (std::chrono::steady_clock::now() >= deadline) throw std::runtime_error("D3D frame completion timed out");
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  { std::lock_guard<std::mutex> lock(mutex_); if (stopped_) return; latest_ = std::move(frame); if (info.flags & MPV_RENDER_FRAME_INFO_PRESENT) ++frames_; textures_->MarkTextureFrameAvailable(texture_id_); }
  mpv_render_context_report_swap(render_);
}
void VideoSurface::Run(std::function<void(std::string)> ready) {
  bool announced = false;
  try {
    Initialize();
    announced = true; ready("");
    while (true) {
      int width, height;
      { std::unique_lock<std::mutex> lock(mutex_); wake_.wait(lock, [this] { return stopped_ || dirty_; }); if (stopped_) break; dirty_ = false; width = requested_width_; height = requested_height_; }
      const bool resized = width != width_ || height != height_;
      if (resized) CreateTarget(width, height);
      const auto updates = mpv_render_context_update(render_);
      if ((updates & MPV_RENDER_UPDATE_FRAME) || resized) Render();
    }
  } catch (const std::exception& exception) {
    { std::lock_guard<std::mutex> lock(mutex_); error_ = exception.what(); }
    if (!announced) ready(exception.what());
  }
  Cleanup();
}
void VideoSurface::Cleanup() {
  if (render_) { mpv_render_context_set_update_callback(render_, nullptr, nullptr); mpv_render_context_free(render_); render_ = nullptr; }
  if (display_ != EGL_NO_DISPLAY) {
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (surface_ != EGL_NO_SURFACE) eglDestroySurface(display_, surface_);
    if (context_ != EGL_NO_CONTEXT) eglDestroyContext(display_, context_);
    eglTerminate(display_);
  }
  if (angle_device_ != EGL_NO_DEVICE_EXT) {
    using ReleaseDevice = EGLBoolean(EGLAPIENTRY*)(EGLDeviceEXT);
    auto releaseDevice = reinterpret_cast<ReleaseDevice>(eglGetProcAddress("eglReleaseDeviceANGLE"));
    if (releaseDevice) releaseDevice(angle_device_);
  }
  target_.Reset(); device_context_.Reset(); device_.Reset();
}
