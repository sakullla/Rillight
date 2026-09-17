#pragma once
#include <flutter/texture_registrar.h>
#include <Windows.h>
#include <d3d11.h>
#include <wrl/client.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <client.h>
#include <render_gl.h>
#include <atomic>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

class VideoSurface : public std::enable_shared_from_this<VideoSurface> {
 public:
  VideoSurface(mpv_handle* player, flutter::TextureRegistrar* textures);
  ~VideoSurface();
  void Start(std::function<void(std::string)> ready);
  void Resize(int width, int height);
  void Stop(std::function<void()> done);
  int64_t texture_id() const { return texture_id_; }
  int64_t frames() const { return frames_.load(); }
  std::string error();
 private:
  struct Frame {
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
    HANDLE handle = nullptr;
    int width = 0, height = 0;
  };
  struct Ticket {
    std::shared_ptr<Frame> frame;
    std::shared_ptr<std::atomic<int>> count;
  };
  const FlutterDesktopGpuSurfaceDescriptor* Obtain();
  static void Update(void* data);
  void Run(std::function<void(std::string)> ready);
  void Initialize();
  void CreateTarget(int width, int height);
  void Render();
  void Cleanup();
  mpv_handle* player_;
  flutter::TextureRegistrar* textures_;
  std::unique_ptr<flutter::TextureVariant> texture_;
  int64_t texture_id_ = -1;
  std::thread worker_;
  std::mutex mutex_;
  std::condition_variable wake_;
  bool stopped_ = false, dirty_ = true;
  int requested_width_ = 1280, requested_height_ = 720;
  std::string error_;
  std::shared_ptr<Frame> latest_;
  FlutterDesktopGpuSurfaceDescriptor descriptor_{};
  std::shared_ptr<std::atomic<int>> tickets_ = std::make_shared<std::atomic<int>>(0);
  std::atomic<int64_t> frames_{0};
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> device_context_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> target_;
  EGLDisplay display_ = EGL_NO_DISPLAY;
  EGLDeviceEXT angle_device_ = EGL_NO_DEVICE_EXT;
  EGLContext context_ = EGL_NO_CONTEXT;
  EGLSurface surface_ = EGL_NO_SURFACE;
  EGLConfig config_ = nullptr;
  int width_ = 0, height_ = 0;
  mpv_render_context* render_ = nullptr;
};
