#include "include/rillight_player/rillight_player_plugin.h"
#include "frame_output.h"
#include "audio_schedule.h"
#include <epoxy/egl.h>
#include <pulse/pulseaudio.h>
#include <pulse/error.h>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdarg>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <time.h>

struct Surface;
typedef struct _RillightTexture { FlPixelBufferTexture parent_instance; std::shared_ptr<Surface>* surface; } RillightTexture;
typedef struct _RillightTextureClass { FlPixelBufferTextureClass parent_class; } RillightTextureClass;
G_DEFINE_TYPE(RillightTexture, rillight_texture, fl_pixel_buffer_texture_get_type())

// The core returns completed CPU RGBA frames even when VAAPI decoded the
// source. Flutter owns the upload context; this plugin creates no producer GL
// context and does not imply zero-copy hardware presentation.

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

// PulseAudio's mainloop is pumped without a blocking wait on the surface
// worker. A suspended or disappearing sink therefore cannot trap detach in
// pa_simple_write while Flutter waits for the producer to retire.
class PulseOutput {
 public:
  PulseOutput() {
    loop_ = pa_mainloop_new();
    if (!loop_) { error_ = "PulseAudio mainloop unavailable"; return; }
    context_ = pa_context_new(pa_mainloop_get_api(loop_), "Rillight");
    if (!context_ || pa_context_connect(context_, nullptr, PA_CONTEXT_NOFLAGS,
                                        nullptr) < 0)
      error_ = "PulseAudio connection unavailable";
  }
  ~PulseOutput() {
    if (stream_) { pa_stream_disconnect(stream_); pa_stream_unref(stream_); }
    if (context_) { pa_context_disconnect(context_); pa_context_unref(context_); }
    if (loop_) pa_mainloop_free(loop_);
  }
  bool Pump() {
    if (!error_.empty()) return false;
    int result = 0;
    if (pa_mainloop_iterate(loop_, 0, &result) < 0) {
      error_ = "PulseAudio mainloop failed"; return false;
    }
    const auto state = pa_context_get_state(context_);
    if (state == PA_CONTEXT_FAILED || state == PA_CONTEXT_TERMINATED) {
      error_ = std::string("PulseAudio: ") + pa_strerror(pa_context_errno(context_));
      return false;
    }
    if (state != PA_CONTEXT_READY) {
      if (std::chrono::steady_clock::now() - started_ >
          std::chrono::seconds(5)) {
        error_ = "PulseAudio connection timed out";
        return false;
      }
      return true;
    }
    if (!stream_) {
      const pa_sample_spec spec{PA_SAMPLE_S16NE, 48000, 2};
      stream_ = pa_stream_new(context_, "Media", &spec, nullptr);
      if (!stream_) { error_ = "PulseAudio stream unavailable"; return false; }
      started_ = std::chrono::steady_clock::now();
      pa_buffer_attr attributes{};
      attributes.maxlength = static_cast<uint32_t>(-1);
      attributes.tlength = 4800;
      attributes.prebuf = 0;
      attributes.minreq = 1920;
      attributes.fragsize = static_cast<uint32_t>(-1);
      if (pa_stream_connect_playback(stream_, nullptr, &attributes,
                                     PA_STREAM_ADJUST_LATENCY, nullptr,
                                     nullptr) < 0) {
        error_ = std::string("PulseAudio stream: ") +
                 pa_strerror(pa_context_errno(context_));
        return false;
      }
    }
    const auto stream_state = pa_stream_get_state(stream_);
    if (stream_state == PA_STREAM_FAILED || stream_state == PA_STREAM_TERMINATED) {
      error_ = std::string("PulseAudio stream: ") +
               pa_strerror(pa_context_errno(context_));
      return false;
    }
    if (stream_state != PA_STREAM_READY &&
        std::chrono::steady_clock::now() - started_ >
            std::chrono::seconds(5)) {
      error_ = "PulseAudio stream timed out";
      return false;
    }
    return true;
  }
  size_t Write(const uint8_t* data, size_t size) {
    if (!stream_ || pa_stream_get_state(stream_) != PA_STREAM_READY) return 0;
    const size_t writable = pa_stream_writable_size(stream_);
    if (writable == static_cast<size_t>(-1)) {
      error_ = "PulseAudio writable size failed"; return 0;
    }
    const size_t chunk = std::min({size, writable, size_t{1920}}) & ~size_t{3};
    if (chunk == 0) return 0;
    if (pa_stream_write(stream_, data, chunk, nullptr, 0,
                        PA_SEEK_RELATIVE) < 0) {
      error_ = std::string("PulseAudio write: ") +
               pa_strerror(pa_context_errno(context_));
      return 0;
    }
    return chunk;
  }
  int64_t Latency() const {
    if (!stream_ || pa_stream_get_state(stream_) != PA_STREAM_READY) return 0;
    pa_usec_t delay = 0;
    int negative = 0;
    if (pa_stream_get_latency(stream_, &delay, &negative) < 0) return -1;
    return negative ? 0 : static_cast<int64_t>(delay);
  }
  void Flush() {
    if (!stream_ || pa_stream_get_state(stream_) != PA_STREAM_READY) return;
    if (auto* operation = pa_stream_flush(stream_, nullptr, nullptr))
      pa_operation_unref(operation);
  }
  void Cork(bool paused) {
    if (!stream_ || pa_stream_get_state(stream_) != PA_STREAM_READY) return;
    if (auto* operation = pa_stream_cork(stream_, paused ? 1 : 0,
                                         nullptr, nullptr))
      pa_operation_unref(operation);
  }
  const std::string& error() const { return error_; }
 private:
  pa_mainloop* loop_ = nullptr;
  pa_context* context_ = nullptr;
  pa_stream* stream_ = nullptr;
  std::string error_;
  std::chrono::steady_clock::time_point started_ =
      std::chrono::steady_clock::now();
};

struct Surface : std::enable_shared_from_this<Surface> {
  using Frame = rillight_linux::PixelFrame;
  RillightCore* core;
  FlTextureRegistrar* registrar;
  RillightTexture* texture = nullptr;
  std::thread worker;
  std::mutex mutex;
  std::condition_variable wake;
  bool stopped = false, registered = false;
  bool detached = false, retired = false, joining = false;
  bool engine_gone = false;
  bool notification_pending = false;
  uint64_t generation = 0;
  int width = 1280, height = 720;
  int rendered_width = 0, rendered_height = 0;
  uint64_t session = 0, timeline = 0;
  uint32_t actual_hardware = 0;
  bool decoded_video = false;
  bool has_video = false;
  bool audio_failed = false;
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

  Surface(RillightCore* p, FlTextureRegistrar* r)
      : core(p), registrar(FL_TEXTURE_REGISTRAR(g_object_ref(r))) {}
  ~Surface() {
    if (worker.joinable()) worker.join();
    g_object_unref(registrar);
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
  void Render(const RillightCoreFrame& source, int w, int h,
              bool new_frame) {
    if (!rillight_linux::ValidSource(source)) {
      std::lock_guard<std::mutex> lock(mutex);
      error = "Core returned invalid RGBA frame";
      stopped = true;
      wake.notify_one();
      return;
    }
    auto frame = std::make_shared<Frame>(rillight_linux::Present(source, w, h));
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (stopped || source.session_id != session ||
          source.timeline_version != timeline) return;
      latest = std::move(frame);
      rendered_width = w;
      rendered_height = h;
      if (new_frame) ++frames;
    }
    Notify();
  }
  void Start(std::function<void(std::string)> ready) {
    worker = std::thread([this, ready] {
      std::unique_ptr<PulseOutput> audio;
      RillightCoreFrame* pending_audio = nullptr;
      int pending_offset = 0;
      int64_t audio_end_pts = -1;
      double audio_speed = 1.0;
      bool audio_clock_started = false;
      bool audio_handed_off = false;
      std::chrono::steady_clock::time_point first_audio_write{};
      RillightCoreFrame* last_video = nullptr;
      RillightCoreState previous_state = RILLIGHT_CORE_IDLE;
      bool audio_corked = false;
      rillight_linux::AudioStartupGate startup_gate;
      rillight_linux::AudioHandoffPolicy handoff_policy;
      uint64_t last_session = 0, last_timeline = 0;
      { std::lock_guard<std::mutex> lock(mutex); latest = std::make_shared<Frame>(); }
      ready("");
      while (true) {
        int w, h;
        {
          std::unique_lock<std::mutex> lock(mutex);
          if (stopped) break;
          w = width; h = height;
        }
        RillightCoreSnapshot snapshot{};
        snapshot.struct_size = sizeof(snapshot);
        if (rillight_core_snapshot(core, &snapshot) != 0 ||
            snapshot.abi_version != RILLIGHT_CORE_ABI_VERSION) {
          std::lock_guard<std::mutex> lock(mutex);
          error = "Core snapshot or ABI unavailable";
          stopped = true;
          break;
        }
        const bool changed = last_session != snapshot.session_id ||
                             last_timeline != snapshot.timeline_version;
        if (changed) {
          if (audio) audio->Flush();
          audio_end_pts = -1;
          audio_clock_started = false;
          audio_handed_off = false;
          first_audio_write = {};
          startup_gate.Reset();
          handoff_policy.Reset();
          if (pending_audio) {
            rillight_core_release_frame(pending_audio);
            pending_audio = nullptr;
            pending_offset = 0;
          }
          if (last_video) { rillight_core_release_frame(last_video); last_video = nullptr; }
          {
            std::lock_guard<std::mutex> lock(mutex);
            session = snapshot.session_id; timeline = snapshot.timeline_version;
            latest = std::make_shared<Frame>();
            rendered_width = rendered_height = 0;
            actual_hardware = 0;
            decoded_video = false;
            has_video = false;
            frames = 0;
          }
          last_session = snapshot.session_id;
          last_timeline = snapshot.timeline_version;
          Notify();
        }
        auto report_audio_clock = [&](int64_t end_pts, int64_t delay,
                                      double speed) {
          RillightCoreSnapshot current{};
          current.struct_size = sizeof(current);
          if (rillight_core_snapshot(core, &current) != 0 ||
              current.session_id != snapshot.session_id ||
              current.timeline_version != snapshot.timeline_version)
            return;
          if (rillight_core_report_audio_played(core, current.session_id,
                                                current.timeline_version,
                                                end_pts,
                                                static_cast<int64_t>(delay * speed)) == 0) {
            audio_clock_started = true;
            audio_handed_off = false;
          }
        };
        if (snapshot.state == RILLIGHT_CORE_PAUSED &&
            previous_state != RILLIGHT_CORE_PAUSED && audio) {
          const int64_t delay = audio->Latency();
          if (audio_end_pts >= 0 && delay >= 0)
            report_audio_clock(audio_end_pts, delay, audio_speed);
          audio->Cork(true);
          audio_corked = true;
        }
        if (snapshot.state == RILLIGHT_CORE_PLAYING && audio_corked && audio) {
          audio->Cork(false);
          audio_corked = false;
        }
        previous_state = snapshot.state;
        {
          std::lock_guard<std::mutex> lock(mutex);
          decoded_video = snapshot.first_video_frame_ready;
          has_video = snapshot.video_stream_index >= 0;
        }

        if (snapshot.video_stream_index >= 0) {
          const int count = rillight_core_track_count(core);
          for (int i = 0; i < count; ++i) {
            RillightCoreTrack track{};
            track.struct_size = sizeof(track);
            if (rillight_core_get_track(core, i, &track) == 0 &&
                track.stream_index == snapshot.video_stream_index &&
                track.type == RILLIGHT_CORE_TRACK_VIDEO) {
              std::lock_guard<std::mutex> lock(mutex);
              actual_hardware = track.actual_hardware;
              break;
            }
          }
        }
        if (snapshot.state == RILLIGHT_CORE_PLAYING &&
            snapshot.audio_stream_index >= 0 && !audio)
          audio = std::make_unique<PulseOutput>();
        if (audio) {
          if (!audio->Pump()) {
            std::lock_guard<std::mutex> lock(mutex);
            error = audio->error();
            audio_failed = stopped = true;
            break;
          }
          const int64_t delay = audio->Latency();
          if (audio_end_pts >= 0 && delay >= 0 &&
              (snapshot.state == RILLIGHT_CORE_PLAYING ||
               snapshot.state == RILLIGHT_CORE_BUFFERING))
            report_audio_clock(audio_end_pts, delay, audio_speed);
        }
        bool audio_progress = false;
        if (snapshot.state == RILLIGHT_CORE_PLAYING && audio) {
          int audio_byte_budget = 19200;
          for (int frames_to_feed = 0;
               frames_to_feed < 8 && audio_byte_budget > 0;
               ++frames_to_feed) {
            if (!pending_audio) {
              pending_audio = rillight_core_take_frame(core,
                                                       RILLIGHT_CORE_AUDIO_S16);
              pending_offset = 0;
            }
            if (!pending_audio) break;
            auto* frame = pending_audio;
            if (frame->session_id != snapshot.session_id ||
                frame->timeline_version != snapshot.timeline_version ||
                frame->sample_rate != 48000 || frame->channels != 2 ||
                frame->data_size != frame->sample_count * 4) {
              rillight_core_release_frame(frame);
              pending_audio = nullptr;
              continue;
            }
            if (!audio_clock_started && frame->pts_us >= 0) {
              RillightCoreSnapshot current{};
              current.struct_size = sizeof(current);
              if (rillight_core_snapshot(core, &current) != 0 ||
                  current.session_id != snapshot.session_id ||
                  current.timeline_version != snapshot.timeline_version)
                break;
              if (frame->pts_us > current.position_us + 50000) break;
              pending_offset = std::max(pending_offset,
                  rillight_linux::StartOffset(*frame,
                      rillight_linux::StartupAudioTarget(current.position_us,
                                                         frame->pts_us),
                                               current.playback_speed));
              if (pending_offset >= frame->data_size) {
                rillight_core_release_frame(frame);
                pending_audio = nullptr;
                continue;
              }
            }
            const int before = pending_offset;
            pending_offset = rillight_linux::DrainPcm(
                frame->data, frame->data_size, pending_offset,
                [&](const uint8_t* data, size_t bytes) {
                  return audio->Write(data, bytes);
                },
                [&](int sent) {
                  const int64_t delay = audio->Latency();
                  if (frame->pts_us < 0) return;
                  const int64_t end_pts = frame->pts_us +
                      static_cast<int64_t>(sent / 4.0 / 48000.0 *
                                           1000000.0 * snapshot.playback_speed);
                  audio_end_pts = end_pts;
                  audio_speed = snapshot.playback_speed;
                  if (first_audio_write ==
                      std::chrono::steady_clock::time_point{})
                    first_audio_write = std::chrono::steady_clock::now();
                  if (delay >= 0)
                    report_audio_clock(end_pts, delay, audio_speed);
                }, audio_byte_budget);
            audio_byte_budget -= pending_offset - before;
            audio_progress |= pending_offset > before;
            if (!audio->error().empty()) {
              std::lock_guard<std::mutex> lock(mutex);
              error = audio->error();
              audio_failed = stopped = true;
              break;
            }
            if (pending_offset < frame->data_size) break;
            rillight_core_release_frame(frame);
            pending_audio = nullptr;
          }
        }
        if (audio_end_pts >= 0 && !audio_clock_started &&
            std::chrono::steady_clock::now() - first_audio_write >
                std::chrono::seconds(2)) {
          std::lock_guard<std::mutex> lock(mutex);
          error = "PulseAudio clock did not start";
          audio_failed = stopped = true;
          break;
        }
        RillightCoreSnapshot handoff_snapshot{};
        handoff_snapshot.struct_size = sizeof(handoff_snapshot);
        if (rillight_core_snapshot(core, &handoff_snapshot) == 0 &&
            handoff_snapshot.session_id == snapshot.session_id &&
            handoff_snapshot.timeline_version == snapshot.timeline_version) {
          const int64_t delay = audio ? audio->Latency() : 0;
          if (handoff_policy.ShouldHandoff(handoff_snapshot,
                  pending_audio != nullptr, delay, audio_clock_started,
                  std::chrono::steady_clock::now()) &&
              rillight_core_report_audio_unavailable(core,
                  snapshot.session_id, snapshot.timeline_version) == 0) {
            audio_end_pts = -1;
            audio_clock_started = false;
            audio_handed_off = true;
            first_audio_write = {};
          }
        }
        auto* video = startup_gate.HoldVideo(
            snapshot, pending_audio, audio_clock_started || audio_handed_off,
            audio_end_pts >= 0,
            std::chrono::steady_clock::now())
            ? nullptr : rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
        if (video) {
          if (video->session_id == snapshot.session_id &&
              video->timeline_version == snapshot.timeline_version) {
            if (last_video) rillight_core_release_frame(last_video);
            last_video = video;
            Render(*last_video, w, h, true);
          } else {
            rillight_core_release_frame(video);
          }
        } else if (last_video &&
                   (rendered_width != w || rendered_height != h)) {
          Render(*last_video, w, h, false);
        }
        if (snapshot.source_eof && snapshot.queued_video_frames == 0 &&
            snapshot.queued_audio_frames == 0 && !pending_audio) {
          const int64_t delay = audio ? audio->Latency() : 0;
          if (delay >= 0 && delay < 10000)
            rillight_core_report_output_drained(core, snapshot.session_id,
                                                snapshot.timeline_version);
        }
        std::unique_lock<std::mutex> lock(mutex);
        const int wait_ms = audio_progress &&
            (pending_audio || snapshot.queued_audio_frames > 0) ? 0 :
            audio && snapshot.state == RILLIGHT_CORE_PLAYING &&
                snapshot.audio_stream_index >= 0 ? 2 : 10;
        wake.wait_for(lock, std::chrono::milliseconds(wait_ms),
                      [this] { return stopped; });
      }
      if (pending_audio) rillight_core_release_frame(pending_audio);
      audio.reset();
      if (last_video) rillight_core_release_frame(last_video);
      {
        std::unique_lock<std::mutex> lock(mutex);
        wake.wait(lock, [this] { return retired; });
      }
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
  // core calls or producer wait occur on this callback.
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
      // core frame references were freed above; normal awaited disposal does not leak.
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
    if (!handle || rillight_core_abi_version() != RILLIGHT_CORE_ABI_VERSION) {
      fl_method_call_respond_error(call, "core", "Core ABI unavailable", nullptr, nullptr);
      return;
    }
    auto* core = reinterpret_cast<RillightCore*>(handle);
    if (rillight_core_configure_hardware(core, RILLIGHT_CORE_HW_VAAPI, 1) != 0) {
      fl_method_call_respond_error(call, "core",
          "Configure VAAPI before opening the Linux core", nullptr, nullptr);
      return;
    }
    auto surface = std::make_shared<Surface>(core, registrar);
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
      }
    }
    surface->wake.notify_one(); RespondSuccess(call);
  } else if (method == "status") {
    std::lock_guard<std::mutex> lock(surface->mutex);
    g_autoptr(FlValue) status = fl_value_new_map();
    fl_value_set_string_take(status, "frames", fl_value_new_int(surface->frames));
    fl_value_set_string_take(status, "error", fl_value_new_string(surface->error.c_str()));
    fl_value_set_string_take(status, "session", fl_value_new_int(surface->session));
    fl_value_set_string_take(status, "timeline", fl_value_new_int(surface->timeline));
    fl_value_set_string_take(status, "actualHardware", fl_value_new_int(surface->actual_hardware));
    const char* decoder = !surface->has_video ? "none" :
        !surface->decoded_video ? "pending" :
        surface->actual_hardware == RILLIGHT_CORE_HW_VAAPI ? "vaapi" : "software";
    fl_value_set_string_take(status, "decoder", fl_value_new_string(decoder));
    fl_value_set_string_take(status, "audioFailed", fl_value_new_bool(surface->audio_failed));
    RespondSuccess(call, status);
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
  PlayerLog("core output plugin registered abi=%u", rillight_core_abi_version());
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
