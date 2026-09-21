#include "include/rillight_player/rillight_player_plugin.h"
#include <epoxy/gl.h>
#include <epoxy/egl.h>
#include <mpv/client.h>
#include <mpv/render.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdarg>
#include <clocale>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <time.h>

struct Surface;
typedef struct _RillightTexture { FlPixelBufferTexture parent_instance; std::shared_ptr<Surface>* surface; } RillightTexture;
typedef struct _RillightTextureClass { FlPixelBufferTextureClass parent_class; } RillightTextureClass;
G_DEFINE_TYPE(RillightTexture, rillight_texture, fl_pixel_buffer_texture_get_type())

// Flutter 3.47 Linux Impeller already owns EGL on the GTK view. A second
// gdk_window_create_gl_context / eglInitialize from this plugin hangs or
// fails on Intel/Mesa/VNC before the HTTP proxy even listens. The published
// texture is already a CPU FlPixelBufferTexture, so libmpv's software
// renderer (MPV_RENDER_API_TYPE_SW) is the matching embed path.

static void PlayerLog(const char* fmt, ...) {
  FILE* log = fopen("/tmp/rillight-gl.log", "a");
  if (!log) return;
  struct timespec ts {};
  clock_gettime(CLOCK_REALTIME, &ts);
  fprintf(log, "%ld.%03ld ", static_cast<long>(ts.tv_sec), ts.tv_nsec / 1000000L);
  va_list ap;
  va_start(ap, fmt);
  vfprintf(log, fmt, ap);
  va_end(ap);
  fputc('\n', log);
  fflush(log);
  fclose(log);
}

// Unlike g_main_context_invoke, attaching a source never executes inline on
// the calling worker. GTK owns and dispatches the default main loop.
static void Main(std::function<void()> callback) {
  auto source = g_idle_source_new();
  g_source_set_priority(source, G_PRIORITY_DEFAULT);
  g_source_set_callback(source, [](gpointer data) -> gboolean {
    (*static_cast<std::function<void()>*>(data))(); return G_SOURCE_REMOVE;
  }, new std::function<void()>(std::move(callback)), [](gpointer data) {
    delete static_cast<std::function<void()>*>(data);
  });
  g_source_attach(source, g_main_context_default());
  g_source_unref(source);
}

struct Surface : std::enable_shared_from_this<Surface> {
  struct Frame {
    int width = 1, height = 1;
    std::vector<uint8_t> pixels = std::vector<uint8_t>(4, 0);
  };
  mpv_handle* player;
  FlTextureRegistrar* registrar;
  RillightTexture* texture = nullptr;
  mpv_render_context* render = nullptr;
  std::thread worker;
  std::mutex mutex;
  std::condition_variable wake;
  bool stopped = false, dirty = true, registered = false;
  bool detached = false, retired = false, joining = false;
  bool engine_gone = false;
  bool notification_pending = false;
  uint64_t generation = 0;
  int width = 1280, height = 720;
  int rendered_width = 0, rendered_height = 0;
  // Immutable CPU frames cross the GDK/Flutter context boundary. At most the
  // latest frame, the raster callback's borrowed frame, and one producer exist.
  std::shared_ptr<const Frame> latest, displayed;
  // Flutter's PixelBufferTexture owns its upload texture in the raster share
  // group. Capture a shared cleanup context before the first upload occurs.
  EGLDisplay cleanup_display = EGL_NO_DISPLAY;
  EGLContext cleanup_context = EGL_NO_CONTEXT;
  EGLenum cleanup_api = EGL_OPENGL_ES_API;
  std::string retirement_error;
  int64_t frames = 0;
  std::string error;
  std::vector<std::function<void()>> release_callbacks;

  Surface(mpv_handle* p, FlTextureRegistrar* r)
      : player(p), registrar(FL_TEXTURE_REGISTRAR(g_object_ref(r))) {}
  ~Surface() {
    if (worker.joinable()) worker.join();
    g_object_unref(registrar);
  }
  static void Update(void* data) {
    auto self = static_cast<Surface*>(data);
    { std::lock_guard<std::mutex> lock(self->mutex); if (self->stopped) return; self->dirty = true; }
    self->wake.notify_one();
  }
  void Notify() {
    uint64_t queued_generation;
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (stopped || !registered || notification_pending) return;
      notification_pending = true; queued_generation = generation;
    }
    auto self = shared_from_this();
    Main([self, queued_generation] {
      std::lock_guard<std::mutex> lock(self->mutex);
      self->notification_pending = false;
      if (self->stopped || !self->registered || self->generation != queued_generation) return;
      fl_texture_registrar_mark_texture_frame_available(self->registrar, FL_TEXTURE(self->texture));
    });
  }
  void Render(int w, int h, bool frame_requested) {
    auto frame = std::make_shared<Frame>();
    frame->width = w;
    frame->height = h;
    const size_t stride = static_cast<size_t>(w) * 4;
    const size_t bytes = stride * static_cast<size_t>(h);
    std::vector<uint8_t> storage(bytes + 64);
    const auto raw = reinterpret_cast<uintptr_t>(storage.data());
    const size_t pad = (64 - (raw % 64)) % 64;
    auto* pixels = storage.data() + pad;
    int size[2] = {w, h};
    char format[] = "rgb0";
    int block = 0;
    size_t stride_value = stride;
    mpv_render_frame_info info{};
    mpv_render_context_get_info(render, {MPV_RENDER_PARAM_NEXT_FRAME_INFO, &info});
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_SW_SIZE, size},
        {MPV_RENDER_PARAM_SW_FORMAT, format},
        {MPV_RENDER_PARAM_SW_STRIDE, &stride_value},
        {MPV_RENDER_PARAM_SW_POINTER, pixels},
        {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block},
        {MPV_RENDER_PARAM_INVALID, nullptr}};
    const int result = mpv_render_context_render(render, params);
    if (result < 0) throw std::runtime_error(mpv_error_string(result));
    for (size_t i = 3; i < bytes; i += 4) pixels[i] = 255;
    frame->pixels.assign(pixels, pixels + bytes);
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (stopped) return;
      latest = std::move(frame);
      rendered_width = w;
      rendered_height = h;
      if (frame_requested && (info.flags & MPV_RENDER_FRAME_INFO_PRESENT)) ++frames;
    }
    Notify();
    mpv_render_context_report_swap(render);
  }
  void Start(std::function<void(std::string)> ready) {
    worker = std::thread([this, ready] {
      bool announced = false;
      try {
        setlocale(LC_NUMERIC, "C");
        PlayerLog("sw-render start");
        int advanced = 1;
        mpv_render_param init[] = {
            {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_SW)},
            {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
            {MPV_RENDER_PARAM_INVALID, nullptr}};
        const int status = mpv_render_context_create(&render, player, init);
        PlayerLog("sw-render create status=%d", status);
        if (status < 0) throw std::runtime_error(mpv_error_string(status));
        { std::lock_guard<std::mutex> lock(mutex); latest = std::make_shared<Frame>(); }
        mpv_render_context_set_update_callback(render, Update, this);
        announced = true; ready("");
        while (true) {
          int w, h;
          {
            std::unique_lock<std::mutex> lock(mutex);
            wake.wait(lock, [this] { return stopped || dirty; });
            if (stopped) break;
            dirty = false; w = width; h = height;
          }
          const auto updates = mpv_render_context_update(render);
          const bool frame_requested = updates & MPV_RENDER_UPDATE_FRAME;
          if (frame_requested || rendered_width != w || rendered_height != h)
            Render(w, h, frame_requested);
        }
      } catch (const std::exception& e) {
        PlayerLog("sw-render error %s", e.what());
        { std::lock_guard<std::mutex> lock(mutex); error = e.what(); stopped = true; ++generation; }
        if (!announced) ready(e.what());
      }
      if (render) {
        mpv_render_context_set_update_callback(render, nullptr, nullptr);
      }
      {
        std::unique_lock<std::mutex> lock(mutex);
        wake.wait(lock, [this] { return retired; });
      }
      if (render) { mpv_render_context_free(render); render = nullptr; }
      {
        std::lock_guard<std::mutex> lock(mutex);
        latest.reset(); displayed.reset();
      }
      ReleasePixelTexture();
    });
  }
  void Quiesce() {
    { std::lock_guard<std::mutex> lock(mutex); stopped = true; ++generation; }
    wake.notify_one();
  }
  // GTK thread only. Return after queuing unregister; retain our GObject ref.
  bool Detach() {
    Quiesce();
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (detached) return true;
      registered = false;
    }
    if (!fl_texture_registrar_unregister_texture(registrar, FL_TEXTURE(texture))) return false;
    { std::lock_guard<std::mutex> lock(mutex); detached = true; }
    return true;
  }
  // Only after Dart's raster barrier or engine shutdown has joined raster.
  // Multiple disposal requests share the same producer join.
  void Retire(std::function<void()> done, bool engine_shutdown = false) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      release_callbacks.push_back(std::move(done));
      engine_gone = engine_gone || engine_shutdown;
      if (joining) return;
      joining = true; stopped = retired = true; registered = false; ++generation;
    }
    wake.notify_one();
    auto self = shared_from_this();
    std::thread([self] {
      if (self->worker.joinable()) self->worker.join();
      Main([self] {
        std::vector<std::function<void()>> callbacks;
        { std::lock_guard<std::mutex> lock(self->mutex); callbacks.swap(self->release_callbacks); }
        for (auto& callback : callbacks) callback();
      });
    }).detach();
  }
  // Called on raster, before FlPixelBufferTexture performs glTexImage2D. No
  // mpv calls or producer wait occur on this callback.
  bool PrepareCleanupContext() {
    if (cleanup_context != EGL_NO_CONTEXT) return true;
    cleanup_display = eglGetCurrentDisplay();
    auto current = eglGetCurrentContext();
    if (cleanup_display == EGL_NO_DISPLAY || current == EGL_NO_CONTEXT) return false;
    EGLint id = 0, version = 2, count = 0;
    if (!eglQueryContext(cleanup_display, current, EGL_CONFIG_ID, &id) ||
        !eglQueryContext(cleanup_display, current, EGL_CONTEXT_CLIENT_VERSION, &version)) return false;
    const EGLint attributes[] = {EGL_CONFIG_ID, id, EGL_NONE};
    EGLConfig config = nullptr;
    if (!eglChooseConfig(cleanup_display, attributes, &config, 1, &count) || !count) return false;
    cleanup_api = eglQueryAPI();
    const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, version, EGL_NONE};
    cleanup_context = eglCreateContext(cleanup_display, config, current, context_attributes);
    return cleanup_context != EGL_NO_CONTEXT;
  }
  // Worker, only after detach -> Dart raster barrier. The parent's dispose
  // deletes a GL texture and must execute with a context in Flutter's share
  // group, not GDK's unrelated producer context or an empty GTK main context.
  void ReleasePixelTexture() {
    std::lock_guard<std::mutex> lock(mutex);
    if (engine_gone) {
      // Engine finalization has already destroyed its EGL display. Deliberately
      // retain the tiny GObject/Surface until process exit instead of invoking
      // the parent's GL destructor against a destroyed context. CPU frames and
      // mpv renderer were freed above; normal awaited disposal does not leak.
      return;
    }
    if (cleanup_context != EGL_NO_CONTEXT &&
        (!eglBindAPI(cleanup_api) ||
         !eglMakeCurrent(cleanup_display, EGL_NO_SURFACE, EGL_NO_SURFACE, cleanup_context))) {
      retirement_error = "Flutter texture cleanup context unavailable; retained for process shutdown";
      return;
    }
    // If never imported, the parent's private texture id is zero and it does
    // not call GL; no cleanup context is needed for that creation-failure path.
    auto released = texture; texture = nullptr;
    if (released) g_object_unref(released);
    if (cleanup_context != EGL_NO_CONTEXT) {
      eglMakeCurrent(cleanup_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
      eglDestroyContext(cleanup_display, cleanup_context);
      cleanup_context = EGL_NO_CONTEXT;
    }
  }
};
static gboolean CopyPixels(FlPixelBufferTexture* base, const uint8_t** buffer, uint32_t* width, uint32_t* height, GError** error) {
  auto texture = reinterpret_cast<RillightTexture*>(base);
  auto self = *texture->surface;
  std::lock_guard<std::mutex> lock(self->mutex);
  if (!self->latest) {
    g_set_error_literal(error, g_quark_from_static_string("rillight-texture"), 1, "Video texture is not initialized");
    return FALSE;
  }
  // Cleanup context is only required at retirement. The upload itself uses
  // Flutter's current raster EGL context; a missing share-group clone must
  // not hide an otherwise valid software frame.
  self->PrepareCleanupContext();
  // An import which started before detach may finish afterward. Its immutable
  // image is retained until the explicit raster barrier authorizes retirement.
  self->displayed = self->latest;
  *buffer = self->displayed->pixels.data();
  *width = self->displayed->width; *height = self->displayed->height;
  return TRUE;
}
static void TextureDispose(GObject* object) {
  auto texture = reinterpret_cast<RillightTexture*>(object);
  delete texture->surface; texture->surface = nullptr;
  G_OBJECT_CLASS(rillight_texture_parent_class)->dispose(object);
}
static void rillight_texture_class_init(RillightTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = CopyPixels;
  G_OBJECT_CLASS(klass)->dispose = TextureDispose;
}
static void rillight_texture_init(RillightTexture* self) { self->surface = nullptr; }

struct Plugin {
  FlPluginRegistrar* registrar = nullptr;
  bool closed = false;
  std::map<int64_t, std::shared_ptr<Surface>> surfaces;
  ~Plugin() { g_clear_object(&registrar); }
};
static int64_t Number(FlValue* args, const char* key) { return fl_value_get_int(fl_value_lookup_string(args, key)); }
static void RespondSuccess(FlMethodCall* call, FlValue* value = nullptr) { fl_method_call_respond_success(call, value, nullptr); }
static void Handle(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto plugin = *static_cast<std::shared_ptr<Plugin>*>(data);
  auto args = fl_method_call_get_args(call);
  const auto handle = Number(args, "handle");
  const std::string method = fl_method_call_get_name(call);
  if (plugin->closed) { fl_method_call_respond_error(call, "closed", "Plugin is closing", nullptr, nullptr); return; }
  if (method == "create") {
    PlayerLog("create handle=%lld", static_cast<long long>(handle));
    if (plugin->surfaces.count(handle)) { fl_method_call_respond_error(call, "duplicate", "Surface already exists", nullptr, nullptr); return; }
    auto registrar = fl_plugin_registrar_get_texture_registrar(plugin->registrar);
    if (!registrar) {
      PlayerLog("create missing texture registrar");
      fl_method_call_respond_error(call, "texture", "Texture registrar unavailable", nullptr, nullptr);
      return;
    }
    auto surface = std::make_shared<Surface>(reinterpret_cast<mpv_handle*>(handle), registrar);
    auto texture = reinterpret_cast<RillightTexture*>(g_object_new(rillight_texture_get_type(), nullptr));
    texture->surface = new std::shared_ptr<Surface>(surface); surface->texture = texture;
    if (!fl_texture_registrar_register_texture(registrar, FL_TEXTURE(texture))) {
      g_object_unref(texture); fl_method_call_respond_error(call, "texture", "Registration failed", nullptr, nullptr); return;
    }
    surface->registered = true;
    plugin->surfaces[handle] = surface;
    g_object_ref(call);
    surface->Start([plugin, call, surface](std::string error) {
      Main([plugin, call, surface, error] {
        if (!plugin->closed) {
          if (error.empty() && surface->texture && !surface->detached) {
            PlayerLog("create ready texture=%lld",
                      static_cast<long long>(fl_texture_get_id(FL_TEXTURE(surface->texture))));
            g_autoptr(FlValue) id = fl_value_new_int(fl_texture_get_id(FL_TEXTURE(surface->texture)));
            RespondSuccess(call, id);
          } else {
            PlayerLog("create failed %s", error.empty() ? "cancelled" : error.c_str());
            // Dart's create-error cleanup follows detach / fence / retire too.
            fl_method_call_respond_error(call, "render", error.empty() ? "Surface creation cancelled" : error.c_str(), nullptr, nullptr);
          }
        }
        g_object_unref(call);
      });
    });
    return;
  }
  auto found = plugin->surfaces.find(handle);
  if (found == plugin->surfaces.end()) {
    if (method == "dispose") RespondSuccess(call);
    else if (method == "detach") { g_autoptr(FlValue) absent = fl_value_new_bool(false); RespondSuccess(call, absent); }
    else fl_method_call_respond_error(call, "missing", "Surface unavailable", nullptr, nullptr);
    return;
  }
  auto surface = found->second;
  if (method == "resize") {
    {
      std::lock_guard<std::mutex> lock(surface->mutex);
      if (!surface->stopped) {
        surface->width = std::clamp(static_cast<int>(Number(args, "width")), 1, 7680);
        surface->height = std::clamp(static_cast<int>(Number(args, "height")), 1, 4320);
        surface->dirty = true;
      }
    }
    surface->wake.notify_one(); RespondSuccess(call);
  } else if (method == "status") {
    std::lock_guard<std::mutex> lock(surface->mutex);
    g_autoptr(FlValue) status = fl_value_new_map();
    fl_value_set_string_take(status, "frames", fl_value_new_int(surface->frames));
    fl_value_set_string_take(status, "error", fl_value_new_string(surface->error.c_str())); RespondSuccess(call, status);
  } else if (method == "detach") {
    if (surface->Detach()) { g_autoptr(FlValue) queued = fl_value_new_bool(true); RespondSuccess(call, queued); }
    else fl_method_call_respond_error(call, "detach", "Texture unregister was not queued", nullptr, nullptr);
  } else if (method == "dispose") {
    if (!surface->detached) { fl_method_call_respond_error(call, "retirement", "Detach and raster barrier required", nullptr, nullptr); return; }
    g_object_ref(call);
    surface->Retire([plugin, surface, handle, call] {
      if (surface->retirement_error.empty()) {
        plugin->surfaces.erase(handle);
        if (!plugin->closed) RespondSuccess(call);
      } else if (!plugin->closed) {
        fl_method_call_respond_error(call, "retirement", surface->retirement_error.c_str(), nullptr, nullptr);
      }
      g_object_unref(call);
    });
  } else fl_method_call_respond_not_implemented(call, nullptr);
}
void rillight_player_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  // libmpv refuses mpv_create() when LC_NUMERIC is not C. Flutter/GTK set a
  // UTF-8 UI locale (zh_CN.UTF-8), so pin numeric formatting for this process.
  setlocale(LC_NUMERIC, "C");
  PlayerLog("plugin registered LC_NUMERIC=%s", setlocale(LC_NUMERIC, nullptr));
  auto plugin = std::make_shared<Plugin>();
  // The generated registrar is a temporary g_autoptr, released immediately
  // after plugin registration. Keep its weak-view/messenger accessors alive.
  plugin->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));
  // Finalization happens after FlutterEngineShutdown has joined raster. This
  // also covers channel loss / dead Dart isolate without guessing at a delay.
  auto engine = fl_view_get_engine(fl_plugin_registrar_get_view(registrar));
  g_object_weak_ref(G_OBJECT(engine), [](gpointer data, GObject*) {
    std::unique_ptr<std::shared_ptr<Plugin>> owner(static_cast<std::shared_ptr<Plugin>*>(data));
    auto plugin = *owner; plugin->closed = true;
    for (auto& entry : plugin->surfaces) entry.second->Retire([] {}, true);
    plugin->surfaces.clear();
  }, new std::shared_ptr<Plugin>(plugin));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar), "rillight_player", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, Handle, new std::shared_ptr<Plugin>(plugin), [](gpointer data) {
    std::unique_ptr<std::shared_ptr<Plugin>> owner(static_cast<std::shared_ptr<Plugin>*>(data));
    auto plugin = *owner; plugin->closed = true;
    // Channel lifetime does not prove raster completion. Quiesce now and keep
    // the resource owners alive until the engine-finalization authority above.
    for (auto& entry : plugin->surfaces) entry.second->Quiesce();
  });
}
