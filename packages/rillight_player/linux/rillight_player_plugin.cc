#include "include/rillight_player/rillight_player_plugin.h"
#include <epoxy/gl.h>
#include <epoxy/egl.h>
#include <epoxy/glx.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>

struct Surface;
typedef struct _RillightTexture { FlTextureGL parent_instance; std::shared_ptr<Surface>* surface; } RillightTexture;
typedef struct _RillightTextureClass { FlTextureGLClass parent_class; } RillightTextureClass;
G_DEFINE_TYPE(RillightTexture, rillight_texture, fl_texture_gl_get_type())

static void Main(std::function<void()> callback) {
  g_main_context_invoke(nullptr, [](gpointer data) -> gboolean {
    std::unique_ptr<std::function<void()>> callback(static_cast<std::function<void()>*>(data));
    (*callback)(); return G_SOURCE_REMOVE;
  }, new std::function<void()>(std::move(callback)));
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
  bool stopped = false, dirty = true;
  int width = 1280, height = 720;
  GLuint latest = 0, displayed = 0;
  int latest_width = 0, latest_height = 0;
  std::set<GLuint> allocated;
  int64_t frames = 0;
  std::string error;
  Surface(mpv_handle* p, FlTextureRegistrar* r, GdkGLContext* c) : player(p), registrar(r), context(c) {}
  ~Surface() { if (worker.joinable()) worker.join(); g_object_unref(context); }
  static void Update(void* data) {
    auto self = static_cast<Surface*>(data);
    { std::lock_guard<std::mutex> lock(self->mutex); if (self->stopped) return; self->dirty = true; }
    self->wake.notify_one();
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
        int status = mpv_render_context_create(&render, player, init);
        if (status < 0) throw std::runtime_error(mpv_error_string(status));
        mpv_render_context_set_update_callback(render, Update, this);
        announced = true; ready("");
        while (true) {
          int w, h;
          { std::unique_lock<std::mutex> lock(mutex); wake.wait(lock, [this] { return stopped || dirty; }); if (stopped) break; dirty = false; w = width; h = height; }
          mpv_render_context_update(render);
          // At most latest, displayed and the frame being produced exist.
          { std::lock_guard<std::mutex> lock(mutex); for (auto it = allocated.begin(); it != allocated.end();) { if (*it != latest && *it != displayed) { GLuint old = *it; glDeleteTextures(1, &old); it = allocated.erase(it); } else ++it; } }
          GLuint image = 0, fbo = 0;
          glGenTextures(1, &image); allocated.insert(image);
          glBindTexture(GL_TEXTURE_2D, image);
          glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
          glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
          glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
          glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
          glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
          glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
          glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, image, 0);
          if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) throw std::runtime_error("Incomplete video framebuffer");
          mpv_opengl_fbo target{static_cast<int>(fbo), w, h, 0}; int flip = 0, block = 0;
          mpv_render_frame_info info{};
          mpv_render_context_get_info(render, {MPV_RENDER_PARAM_NEXT_FRAME_INFO, &info});
          mpv_render_param params[] = {{MPV_RENDER_PARAM_OPENGL_FBO, &target}, {MPV_RENDER_PARAM_FLIP_Y, &flip}, {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block}, {MPV_RENDER_PARAM_INVALID, nullptr}};
          int rendered = mpv_render_context_render(render, params);
          glFinish(); glDeleteFramebuffers(1, &fbo);
          if (rendered < 0) throw std::runtime_error(mpv_error_string(rendered));
          { std::lock_guard<std::mutex> lock(mutex); if (stopped) break; latest = image; latest_width = w; latest_height = h; if (info.flags & MPV_RENDER_FRAME_INFO_PRESENT) ++frames; fl_texture_registrar_mark_texture_frame_available(registrar, FL_TEXTURE(texture)); }
          mpv_render_context_report_swap(render);
        }
      } catch (const std::exception& e) { { std::lock_guard<std::mutex> lock(mutex); error = e.what(); } if (!announced) ready(e.what()); }
      if (render) { mpv_render_context_set_update_callback(render, nullptr, nullptr); mpv_render_context_free(render); render = nullptr; }
      // Stop is called after unregister, so no new import can race deletion.
      { std::lock_guard<std::mutex> lock(mutex); for (auto image : allocated) glDeleteTextures(1, &image); allocated.clear(); latest = displayed = 0; }
      gdk_gl_context_clear_current();
    });
  }
  void Stop(std::function<void()> done) {
    { std::lock_guard<std::mutex> lock(mutex); stopped = true; }
    fl_texture_registrar_unregister_texture(registrar, FL_TEXTURE(texture));
    wake.notify_one();
    auto self = shared_from_this();
    std::thread([self, done] { if (self->worker.joinable()) self->worker.join(); Main(done); }).detach();
  }
};
static gboolean Populate(FlTextureGL* base, uint32_t* target, uint32_t* name, uint32_t* width, uint32_t* height, GError**) {
  auto texture = reinterpret_cast<RillightTexture*>(base);
  auto self = *texture->surface;
  std::lock_guard<std::mutex> lock(self->mutex);
  if (self->stopped || !self->latest) return FALSE;
  self->displayed = self->latest;
  *target = GL_TEXTURE_2D; *name = self->displayed; *width = self->latest_width; *height = self->latest_height;
  return TRUE;
}
static void TextureDispose(GObject* object) {
  auto texture = reinterpret_cast<RillightTexture*>(object);
  delete texture->surface; texture->surface = nullptr;
  G_OBJECT_CLASS(rillight_texture_parent_class)->dispose(object);
}
static void rillight_texture_class_init(RillightTextureClass* klass) { FL_TEXTURE_GL_CLASS(klass)->populate = Populate; G_OBJECT_CLASS(klass)->dispose = TextureDispose; }
static void rillight_texture_init(RillightTexture* self) { self->surface = nullptr; }

struct Plugin { FlPluginRegistrar* registrar; std::map<int64_t, std::shared_ptr<Surface>> surfaces; };
static int64_t Number(FlValue* args, const char* key) { return fl_value_get_int(fl_value_lookup_string(args, key)); }
static void Success(FlMethodCall* call, FlValue* value = nullptr) { fl_method_call_respond_success(call, value, nullptr); }
static void Handle(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto plugin = static_cast<Plugin*>(data);
  auto args = fl_method_call_get_args(call);
  const auto handle = Number(args, "handle");
  const std::string method = fl_method_call_get_name(call);
  if (method == "create") {
    if (plugin->surfaces.count(handle)) { fl_method_call_respond_error(call, "duplicate", "Surface already exists", nullptr, nullptr); return; }
    auto view = fl_plugin_registrar_get_view(plugin->registrar);
    GError* error = nullptr;
    auto context = gdk_window_create_gl_context(gtk_widget_get_window(GTK_WIDGET(view)), &error);
    if (!context || !gdk_gl_context_realize(context, &error)) { fl_method_call_respond_error(call, "gl-context", error ? error->message : "No GL context", nullptr, nullptr); g_clear_error(&error); if (context) g_object_unref(context); return; }
    auto registrar = fl_plugin_registrar_get_texture_registrar(plugin->registrar);
    auto surface = std::make_shared<Surface>(reinterpret_cast<mpv_handle*>(handle), registrar, context);
    auto texture = reinterpret_cast<RillightTexture*>(g_object_new(rillight_texture_get_type(), nullptr));
    texture->surface = new std::shared_ptr<Surface>(surface); surface->texture = texture;
    if (!fl_texture_registrar_register_texture(registrar, FL_TEXTURE(texture))) { g_object_unref(texture); fl_method_call_respond_error(call, "texture", "Registration failed", nullptr, nullptr); return; }
    plugin->surfaces[handle] = surface;
    g_object_ref(call);
    surface->Start([plugin, call, surface, handle](std::string error) { Main([plugin, call, surface, handle, error] {
      if (error.empty()) { g_autoptr(FlValue) id = fl_value_new_int(fl_texture_get_id(FL_TEXTURE(surface->texture))); Success(call, id); g_object_unref(call); }
      else surface->Stop([plugin, call, surface, handle, error] { g_object_unref(surface->texture); plugin->surfaces.erase(handle); fl_method_call_respond_error(call, "render", error.c_str(), nullptr, nullptr); g_object_unref(call); });
    }); });
    return;
  }
  auto found = plugin->surfaces.find(handle);
  if (found == plugin->surfaces.end()) { if (method == "dispose") Success(call); else fl_method_call_respond_error(call, "missing", "Surface unavailable", nullptr, nullptr); return; }
  auto surface = found->second;
  if (method == "resize") { { std::lock_guard<std::mutex> lock(surface->mutex); surface->width = std::clamp(static_cast<int>(Number(args, "width")), 1, 7680); surface->height = std::clamp(static_cast<int>(Number(args, "height")), 1, 4320); surface->dirty = true; } surface->wake.notify_one(); Success(call); }
  else if (method == "status") { std::lock_guard<std::mutex> lock(surface->mutex); g_autoptr(FlValue) status = fl_value_new_map(); fl_value_set_string_take(status, "frames", fl_value_new_int(surface->frames)); fl_value_set_string_take(status, "error", fl_value_new_string(surface->error.c_str())); Success(call, status); }
  else if (method == "dispose") { g_object_ref(call); surface->Stop([plugin, surface, handle, call] { g_object_unref(surface->texture); plugin->surfaces.erase(handle); Success(call); g_object_unref(call); }); }
  else fl_method_call_respond_not_implemented(call, nullptr);
}
void rillight_player_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  auto plugin = new Plugin{registrar, {}};
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar), "rillight_player", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, Handle, plugin, [](gpointer data) {
    auto plugin = static_cast<Plugin*>(data);
    // Registrar shutdown owns any remaining textures; normal Dart shutdown
    // awaits dispose before engine teardown.
    for (auto& entry : plugin->surfaces) { auto surface = entry.second; surface->Stop([surface] { g_object_unref(surface->texture); }); }
    delete plugin;
  });
}
