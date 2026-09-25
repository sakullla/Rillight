#include "include/rillight_player/rillight_player_plugin_c_api.h"
#include "video_surface.h"
#include "core_api.h"
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <map>
#include <mutex>
#include <optional>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;
constexpr UINT kDispatch = WM_APP + 0x3e1;
struct DispatchQueue {
  explicit DispatchQueue(HWND window) : window(window) {}
  HWND window;
  std::mutex mutex;
  bool alive = true;
  uint64_t next_id = 1;
  std::map<uint64_t, std::function<void()>> pending;
};

void Post(const std::shared_ptr<DispatchQueue>& dispatch,
          std::function<void()> callback) {
  uint64_t id;
  {
    std::lock_guard lock(dispatch->mutex);
    if (!dispatch->alive) return;
    id = dispatch->next_id++;
    dispatch->pending.emplace(id, std::move(callback));
  }
  const HWND root = GetAncestor(dispatch->window, GA_ROOT);
  if (!root || !PostMessage(root, kDispatch,
                            reinterpret_cast<WPARAM>(dispatch.get()),
                            static_cast<LPARAM>(id))) {
    std::lock_guard lock(dispatch->mutex);
    dispatch->pending.erase(id);
  }
}
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
    dispatch_ = std::make_shared<DispatchQueue>(window_);
    delegate_ = registrar_->RegisterTopLevelWindowProcDelegate([dispatch = dispatch_](HWND, UINT message, WPARAM owner, LPARAM task) -> std::optional<LRESULT> {
      if (message != kDispatch ||
          owner != reinterpret_cast<WPARAM>(dispatch.get())) return std::nullopt;
      std::function<void()> callback;
      {
        std::lock_guard lock(dispatch->mutex);
        const auto found = dispatch->pending.find(static_cast<uint64_t>(task));
        if (found != dispatch->pending.end()) {
          callback = std::move(found->second);
          dispatch->pending.erase(found);
        }
      }
      if (callback) callback();
      return 0;
    });
    channel_ = std::make_unique<flutter::MethodChannel<Value>>(registrar_->messenger(), "rillight_player", &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto& call, auto result) { Handle(call, std::move(result)); });
  }
  ~RillightPlayerPlugin() override {
    {
      std::lock_guard lock(dispatch_->mutex);
      dispatch_->alive = false;
      dispatch_->pending.clear();
    }
    for (auto& entry : outstanding_) {
      entry.second->Error("player-shutdown", "Player window closed");
    }
    outstanding_.clear();
    // Normal ownership is Dart dispose -> unregister -> renderer free -> core
    // destroy. This is only an engine shutdown safety net.
    for (auto& entry : surfaces_) entry.second->Stop([] {});
    registrar_->UnregisterTopLevelWindowProcDelegate(delegate_);
  }
 private:
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
        const uint64_t request = next_result_id_++;
        outstanding_[request] = result;
        auto dispatch = dispatch_;
        surface->Start([this, dispatch, result, surface, handle, request](std::string error) {
          Post(dispatch, [this, dispatch, result, surface, handle, request, error] {
            if (error.empty()) {
              outstanding_.erase(request);
              result->Success(Value(surface->texture_id()));
            } else surface->Stop([this, dispatch, result, handle, request, error] {
              Post(dispatch, [this, result, handle, request, error] {
                surfaces_.erase(handle);
                outstanding_.erase(request);
                result->Error("render-create", error);
              });
            });
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
            {Value("audioWarning"), Value(surface->audio_warning())},
            {Value("actualHardware"), Value(static_cast<int32_t>(actual_hardware))},
        }));
      } else if (method == "dispose") {
        const uint64_t request = next_result_id_++;
        outstanding_[request] = result;
        auto dispatch = dispatch_;
        surface->Stop([this, dispatch, result, handle, request] {
          Post(dispatch, [this, result, handle, request] {
            surfaces_.erase(handle);
            outstanding_.erase(request);
            result->Success();
          });
        });
      } else result->NotImplemented();
    } catch (const std::exception& exception) { result->Error("native-player", exception.what()); }
  }
  flutter::PluginRegistrarWindows* registrar_;
  HWND window_;
  int delegate_;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  std::shared_ptr<CoreApi> api_;
  std::shared_ptr<DispatchQueue> dispatch_;
  uint64_t next_result_id_ = 1;
  std::map<uint64_t, std::shared_ptr<Result>> outstanding_;
  std::map<int64_t, std::shared_ptr<VideoSurface>> surfaces_;
};
}
void RillightPlayerPluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  auto windows = flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  windows->AddPlugin(std::make_unique<RillightPlayerPlugin>(windows));
}
