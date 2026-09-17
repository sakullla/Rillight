#include "../../windows/video_surface.h"
#include <future>
#include <iostream>
#include <set>
#include <vector>

class Registrar : public flutter::TextureRegistrar {
 public:
  flutter::TextureVariant* texture = nullptr;
  std::atomic<int> notified{0};
  int64_t RegisterTexture(flutter::TextureVariant* value) override { texture = value; return 1; }
  bool MarkTextureFrameAvailable(int64_t) override { ++notified; return true; }
  void UnregisterTexture(int64_t, std::function<void()> done) override { texture = nullptr; done(); }
  bool UnregisterTexture(int64_t) override { return true; }
};
int main(int argc, char** argv) {
  if (argc < 2) return 2;
  auto player = mpv_create();
  if (!player) return 3;
  mpv_set_option_string(player, "vo", "libmpv");
  mpv_set_option_string(player, "ao", "null");
  mpv_set_option_string(player, "hwdec", "auto-copy");
  mpv_set_option_string(player, "keep-open", "yes");
  if (mpv_initialize(player) < 0) return 4;
  Registrar registrar;
  auto surface = std::make_shared<VideoSurface>(player, &registrar);
  std::promise<std::string> ready;
  surface->Start([&](auto error) { ready.set_value(error); });
  auto error = ready.get_future().get();
  if (!error.empty()) { std::cerr << error << '\n'; std::promise<void> closed; surface->Stop([&] { closed.set_value(); }); closed.get_future().get(); mpv_terminate_destroy(player); return 5; }
  const char* load[] = {"loadfile", argv[1], "replace", nullptr};
  if (mpv_command(player, load) < 0) return 6;
  std::set<HANDLE> handles;
  int imports = 0;
  bool resized = false;
  for (int i = 0; i < 400; ++i) {
    auto event = mpv_wait_event(player, 0);
    if (event->event_id == MPV_EVENT_END_FILE && static_cast<mpv_event_end_file*>(event->data)->error < 0) return 7;
    if (registrar.texture) {
      auto descriptor = std::get<flutter::GpuSurfaceTexture>(*registrar.texture).ObtainDescriptor(1280, 720);
      if (descriptor) {
        handles.insert(static_cast<HANDLE>(descriptor->handle));
        descriptor->release_callback(descriptor->release_context);
        // Mirrors Flutter's access after release_callback; regression for UAF.
        if (descriptor->visible_width == 640 && descriptor->visible_height == 360) resized = true;
        ++imports;
      }
    }
    if (i == 100) surface->Resize(640, 360);
    if (i == 200) { const char* seek[] = {"seek", "1", "absolute+exact", nullptr}; mpv_command(player, seek); }
    if (i == 300) surface->Resize(1920, 1080);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  auto frames = surface->frames();
  error = surface->error();
  std::vector<std::pair<void (*)(void*), void*>> held;
  auto& gpu = std::get<flutter::GpuSurfaceTexture>(*registrar.texture);
  for (int i = 0; i < 8; ++i) {
    auto descriptor = gpu.ObtainDescriptor(1920, 1080);
    if (!descriptor) return 10;
    held.push_back({descriptor->release_callback, descriptor->release_context});
  }
  const bool bounded = gpu.ObtainDescriptor(1920, 1080) == nullptr;
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  for (auto ticket : held) ticket.first(ticket.second);
  auto recovered = gpu.ObtainDescriptor(1920, 1080);
  if (!recovered) return 11;
  recovered->release_callback(recovered->release_context);
  std::promise<void> closed;
  surface->Stop([&] { closed.set_value(); });
  closed.get_future().get();
  auto notifications = registrar.notified.load();
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  if (registrar.notified != notifications) return 8;
  surface.reset();
  mpv_terminate_destroy(player);
  std::cout << "frames=" << frames << " imports=" << imports << " distinct_handles=" << handles.size() << " resized=" << resized << " bounded=" << bounded << " error=" << error << '\n';
  return frames > 20 && handles.size() > 5 && resized && bounded && error.empty() ? 0 : 9;
}
