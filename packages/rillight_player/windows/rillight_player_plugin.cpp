#include "include/rillight_player/rillight_player_plugin_c_api.h"
#include "video_surface.h"
#include "core_api.h"
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <map>
#include <optional>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;
constexpr UINT kDispatch = WM_APP + 0x3e1;
int64_t Number(const Map& args, const char* key) {
  const auto& value = args.at(Value(key));
  if (auto integer = std::get_if<int32_t>(&value)) return *integer;
  return std::get<int64_t>(value);
}
class RillightPlayerPlugin : public flutter::Plugin {
 public:
  explicit RillightPlayerPlugin(flutter::PluginRegistrarWindows* registrar) : registrar_(registrar) {
    // Plugin registration precedes SetChildContent in the standard runner.
    // Keep the stable child HWND, but resolve its parent only when posting.
    window_ = registrar_->GetView()->GetNativeWindow();
    delegate_ = registrar_->RegisterTopLevelWindowProcDelegate([this](HWND, UINT message, WPARAM owner, LPARAM task) -> std::optional<LRESULT> {
      if (message != kDispatch || owner != reinterpret_cast<WPARAM>(this)) return std::nullopt;
      std::unique_ptr<std::function<void()>> callback(reinterpret_cast<std::function<void()>*>(task));
      (*callback)();
      return 0;
    });
    channel_ = std::make_unique<flutter::MethodChannel<Value>>(registrar_->messenger(), "rillight_player", &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto& call, auto result) { Handle(call, std::move(result)); });
  }
  ~RillightPlayerPlugin() override {
    // Normal ownership is Dart dispose -> unregister -> renderer free -> core
    // destroy. This is only an engine shutdown safety net.
    for (auto& entry : surfaces_) entry.second->Stop([] {});
    registrar_->UnregisterTopLevelWindowProcDelegate(delegate_);
  }
 private:
  void Post(std::function<void()> callback) {
    auto task = new std::function<void()>(std::move(callback));
    const HWND root = GetAncestor(window_, GA_ROOT);
    if (!PostMessage(root, kDispatch, reinterpret_cast<WPARAM>(this), reinterpret_cast<LPARAM>(task))) delete task;
  }
  void Handle(const flutter::MethodCall<Value>& call, std::unique_ptr<Result> uniqueResult) {
    auto result = std::shared_ptr<Result>(std::move(uniqueResult));
    try {
      const auto& args = std::get<Map>(*call.arguments());
      const auto handle = Number(args, "handle");
      const auto method = call.method_name();
      if (method == "create") {
        if (surfaces_.count(handle)) throw std::runtime_error("Surface already exists");
        if (!api_) api_ = std::make_shared<CoreApi>();
        auto surface = std::make_shared<VideoSurface>(
            reinterpret_cast<RillightCore*>(handle), api_,
            registrar_->texture_registrar());
        surfaces_[handle] = surface;
        surface->Start([this, result, surface, handle](std::string error) {
          Post([this, result, surface, handle, error] {
            if (error.empty()) result->Success(Value(surface->texture_id()));
            else surface->Stop([this, result, handle, error] { Post([this, result, handle, error] { surfaces_.erase(handle); result->Error("render-create", error); }); });
          });
        });
        return;
      }
      const auto found = surfaces_.find(handle);
      if (found == surfaces_.end()) {
        if (method == "dispose") result->Success();
        else result->Error("missing-surface", "Player surface is unavailable");
        return;
      }
      auto surface = found->second;
      if (method == "resize") {
        surface->Resize(static_cast<int>(Number(args, "width")), static_cast<int>(Number(args, "height")));
        result->Success();
      } else if (method == "status") {
        uint32_t actual_hardware = 0;
        const int count = api_->track_count(reinterpret_cast<RillightCore*>(handle));
        for (int index = 0; index < count; ++index) {
          RillightCoreTrack track{};
          track.struct_size = sizeof(track);
          if (api_->get_track(reinterpret_cast<RillightCore*>(handle), index,
                              &track) == 0 &&
              track.type == RILLIGHT_CORE_TRACK_VIDEO) {
            actual_hardware = track.actual_hardware;
            break;
          }
        }
        result->Success(Value(Map{
            {Value("frames"), Value(surface->frames())},
            {Value("error"), Value(surface->error())},
            {Value("actualHardware"), Value(static_cast<int32_t>(actual_hardware))},
        }));
      } else if (method == "dispose") {
        surface->Stop([this, result, handle] { Post([this, result, handle] { surfaces_.erase(handle); result->Success(); }); });
      } else result->NotImplemented();
    } catch (const std::exception& exception) { result->Error("native-player", exception.what()); }
  }
  flutter::PluginRegistrarWindows* registrar_;
  HWND window_;
  int delegate_;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  std::shared_ptr<CoreApi> api_;
  std::map<int64_t, std::shared_ptr<VideoSurface>> surfaces_;
};
}
void RillightPlayerPluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  auto windows = flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  windows->AddPlugin(std::make_unique<RillightPlayerPlugin>(windows));
}
