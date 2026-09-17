#include "include/rillight_player/rillight_player_plugin.h"
#include <epoxy/gl.h>
#include <epoxy/egl.h>
#include <epoxy/glx.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <algorithm>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

struct Surface;
typedef struct _RillightTexture { FlTextureGL parent_instance; std::shared_ptr<Surface>* surface; } RillightTexture;
typedef struct _RillightTextureClass { FlTextureGLClass parent_class; } RillightTextureClass;
G_DEFINE_TYPE(RillightTexture, rillight_texture, fl_texture_gl_get_type())

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
  mpv_handle* player;
  FlTextureRegistrar* registrar;
  RillightTexture* texture = nullptr;
  GdkGLContext* context;
  mpv_render_context* render = nullptr;
  std::thread worker;
  std::mutex mutex;
  std::condition_variable wake;
  bool stopped = false, dirty = true, registered = false;
  bool detached = false, retired = false, joining = false;
  bool notification_pending = false;
  uint64_t generation = 0;
  int width = 1280, height = 720;
  GLuint latest = 0, displayed = 0;
  int latest_width = 0, latest_height = 0;
  // Producer-only set; after stopping, no image is freed until the raster fence.
  std::set<GLuint> allocated;
  int64_t frames = 0;
  std::string error;
  std::vector<std::function<void()>> release_callbacks;

  Surface(mpv_handle* p, FlTextureRegistrar* r, GdkGLContext* c)
      : player(p), registrar(FL_TEXTURE_REGISTRAR(g_object_ref(r))), context(c) {}
  ~Surface() {
    if (worker.joinable()) worker.join();
    g_object_unref(context); g_object_unref(registrar);
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
  GLuint Allocate(int w, int h) {
    GLuint image = 0;
    glGenTextures(1, &image); allocated.insert(image);
    glBindTexture(GL_TEXTURE_2D, image);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    return image;
  }
  void Render(int w, int h) {
    // Flutter flushes prior draws before its next Populate. Retire old objects;
    // never overwrite an allocation which Flutter has imported.
    {
      std::lock_guard<std::mutex> lock(mutex);
      for (auto it = allocated.begin(); it != allocated.end();) {
        if (*it != latest && *it != displayed) {
          GLuint old = *it; glDeleteTextures(1, &old); it = allocated.erase(it);
        } else ++it;
      }
    }
    const GLuint image = Allocate(w, h);
    struct Framebuffer {
      GLuint id = 0;
      Framebuffer() { glGenFramebuffers(1, &id); }
      ~Framebuffer() { glDeleteFramebuffers(1, &id); }
    } fbo;
    glBindFramebuffer(GL_FRAMEBUFFER, fbo.id);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, image, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
      throw std::runtime_error("Incomplete video framebuffer");
    mpv_opengl_fbo target{static_cast<int>(fbo.id), w, h, 0};
    // control.dart enforces video-timing-offset=0 for the nonblocking renderer.
    int flip = 0, block = 0;
    mpv_render_frame_info info{};
    mpv_render_context_get_info(render, {MPV_RENDER_PARAM_NEXT_FRAME_INFO, &info});
    mpv_render_param params[] = {{MPV_RENDER_PARAM_OPENGL_FBO, &target}, {MPV_RENDER_PARAM_FLIP_Y, &flip}, {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block}, {MPV_RENDER_PARAM_INVALID, nullptr}};
    const int result = mpv_render_context_render(render, params);
    glFinish();
    if (result < 0) throw std::runtime_error(mpv_error_string(result));
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (stopped) return;
      latest = image; latest_width = w; latest_height = h;
      if (info.flags & MPV_RENDER_FRAME_INFO_PRESENT) ++frames;
    }
    Notify();
    mpv_render_context_report_swap(render);
  }
  void Start(std::function<void(std::string)> ready) {
    worker = std::thread([this, ready] {
      bool announced = false;
      try {
        gdk_gl_context_make_current(context);
        mpv_opengl_init_params gl{[](void*, const char* name) -> void* {
          if (eglGetCurrentContext() != EGL_NO_CONTEXT) return reinterpret_cast<void*>(eglGetProcAddress(name));
          return reinterpret_cast<void*>(glXGetProcAddressARB(reinterpret_cast<const GLubyte*>(name)));
        }, nullptr};
        int advanced = 1;
        mpv_render_param init[] = {{MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_OPENGL)}, {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl}, {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced}, {MPV_RENDER_PARAM_INVALID, nullptr}};
        const int status = mpv_render_context_create(&render, player, init);
        if (status < 0) throw std::runtime_error(mpv_error_string(status));
        // An import before the first video frame still gets a valid, initialized
        // image. Finish initializing it before returning the texture ID.
        const GLuint initial = Allocate(1, 1);
        const uint32_t transparent = 0;
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &transparent);
        glFinish();
        { std::lock_guard<std::mutex> lock(mutex); latest = initial; latest_width = latest_height = 1; }
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
          mpv_render_context_update(render);
          Render(w, h);
        }
      } catch (const std::exception& e) {
        { std::lock_guard<std::mutex> lock(mutex); error = e.what(); stopped = true; ++generation; }
        if (!announced) ready(e.what());
      }
      if (render) {
        mpv_render_context_set_update_callback(render, nullptr, nullptr);
        mpv_render_context_free(render); render = nullptr;
      }
      // Includes errors during initialization/render. Neither stopping nor
      // queuing unregister authorizes deletion of consumer-owned resources.
      {
        std::unique_lock<std::mutex> lock(mutex);
        wake.wait(lock, [this] { return retired; });
        for (auto image : allocated) glDeleteTextures(1, &image);
        allocated.clear(); latest = displayed = 0;
      }
      gdk_gl_context_clear_current();
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
  void Retire(std::function<void()> done) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      release_callbacks.push_back(std::move(done));
      if (joining) return;
      joining = true; stopped = retired = true; registered = false; ++generation;
    }
    wake.notify_one();
    auto self = shared_from_this();
    std::thread([self] {
      if (self->worker.joinable()) self->worker.join();
      Main([self] {
        auto texture = self->texture; self->texture = nullptr;
        if (texture) g_object_unref(texture);
        std::vector<std::function<void()>> callbacks;
        { std::lock_guard<std::mutex> lock(self->mutex); callbacks.swap(self->release_callbacks); }
        for (auto& callback : callbacks) callback();
      });
    }).detach();
  }
};
static gboolean Populate(FlTextureGL* base, uint32_t* target, uint32_t* name, uint32_t* width, uint32_t* height, GError** error) {
  auto texture = reinterpret_cast<RillightTexture*>(base);
  auto self = *texture->surface;
  std::lock_guard<std::mutex> lock(self->mutex);
  if (!self->latest) {
    g_set_error_literal(error, g_quark_from_static_string("rillight-texture"), 1, "Video texture is not initialized");
    return FALSE;
  }
  // An import which started before detach may finish afterward. Its immutable
  // image is retained until the explicit raster barrier authorizes retirement.
  self->displayed = self->latest;
  *target = GL_TEXTURE_2D; *name = self->displayed; *width = self->latest_width; *height = self->latest_height;
  return TRUE;
}
static void TextureDispose(GObject* object) {
  auto texture = reinterpret_cast<RillightTexture*>(object);
  delete texture->surface; texture->surface = nullptr;
  G_OBJECT_CLASS(rillight_texture_parent_class)->dispose(object);
}
static void rillight_texture_class_init(RillightTextureClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = Populate;
  G_OBJECT_CLASS(klass)->dispose = TextureDispose;
}
static void rillight_texture_init(RillightTexture* self) { self->surface = nullptr; }

struct Plugin {
  FlPluginRegistrar* registrar;
  bool closed = false;
  std::map<int64_t, std::shared_ptr<Surface>> surfaces;
};
static int64_t Number(FlValue* args, const char* key) { return fl_value_get_int(fl_value_lookup_string(args, key)); }
static void Success(FlMethodCall* call, FlValue* value = nullptr) { fl_method_call_respond_success(call, value, nullptr); }
static void Handle(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto plugin = *static_cast<std::shared_ptr<Plugin>*>(data);
  auto args = fl_method_call_get_args(call);
  const auto handle = Number(args, "handle");
  const std::string method = fl_method_call_get_name(call);
  if (plugin->closed) { fl_method_call_respond_error(call, "closed", "Plugin is closing", nullptr, nullptr); return; }
  if (method == "create") {
    if (plugin->surfaces.count(handle)) { fl_method_call_respond_error(call, "duplicate", "Surface already exists", nullptr, nullptr); return; }
    auto view = fl_plugin_registrar_get_view(plugin->registrar);
    GError* error = nullptr;
    auto context = gdk_window_create_gl_context(gtk_widget_get_window(GTK_WIDGET(view)), &error);
    if (!context || !gdk_gl_context_realize(context, &error)) {
      fl_method_call_respond_error(call, "gl-context", error ? error->message : "No GL context", nullptr, nullptr);
      g_clear_error(&error); if (context) g_object_unref(context); return;
    }
    auto registrar = fl_plugin_registrar_get_texture_registrar(plugin->registrar);
    auto surface = std::make_shared<Surface>(reinterpret_cast<mpv_handle*>(handle), registrar, context);
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
            g_autoptr(FlValue) id = fl_value_new_int(fl_texture_get_id(FL_TEXTURE(surface->texture)));
            Success(call, id);
          } else {
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
    if (method == "dispose") Success(call);
    else if (method == "detach") { g_autoptr(FlValue) absent = fl_value_new_bool(false); Success(call, absent); }
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
    surface->wake.notify_one(); Success(call);
  } else if (method == "status") {
    std::lock_guard<std::mutex> lock(surface->mutex);
    g_autoptr(FlValue) status = fl_value_new_map();
    fl_value_set_string_take(status, "frames", fl_value_new_int(surface->frames));
    fl_value_set_string_take(status, "error", fl_value_new_string(surface->error.c_str())); Success(call, status);
  } else if (method == "detach") {
    if (surface->Detach()) { g_autoptr(FlValue) queued = fl_value_new_bool(true); Success(call, queued); }
    else fl_method_call_respond_error(call, "detach", "Texture unregister was not queued", nullptr, nullptr);
  } else if (method == "dispose") {
    if (!surface->detached) { fl_method_call_respond_error(call, "retirement", "Detach and raster barrier required", nullptr, nullptr); return; }
    g_object_ref(call);
    surface->Retire([plugin, surface, handle, call] {
      plugin->surfaces.erase(handle);
      if (!plugin->closed) Success(call);
      g_object_unref(call);
    });
  } else fl_method_call_respond_not_implemented(call, nullptr);
}
void rillight_player_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  auto plugin = std::make_shared<Plugin>(); plugin->registrar = registrar;
  // Finalization happens after FlutterEngineShutdown has joined raster. This
  // also covers channel loss / dead Dart isolate without guessing at a delay.
  auto engine = fl_view_get_engine(fl_plugin_registrar_get_view(registrar));
  g_object_weak_ref(G_OBJECT(engine), [](gpointer data, GObject*) {
    std::unique_ptr<std::shared_ptr<Plugin>> owner(static_cast<std::shared_ptr<Plugin>*>(data));
    auto plugin = *owner; plugin->closed = true;
    for (auto& entry : plugin->surfaces) entry.second->Retire([] {});
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
