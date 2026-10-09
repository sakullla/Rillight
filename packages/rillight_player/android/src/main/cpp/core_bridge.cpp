#include <jni.h>
#include <dlfcn.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>

#include "rillight_core.h"
#include "android_tunnel.h"
#include "decoder_probe.h"
#include "media_io_roles.h"
#include "rgba_surface_copy.h"

extern "C" {
#include <libavcodec/jni.h>
}

extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *) {
  // NDK decoding still needs the VM for MediaCodecList profile discovery.
  // MIME alone cannot distinguish HEVC, AVC and AV1 Dolby Vision decoders.
  return av_jni_set_java_vm(vm, nullptr) == 0 ? JNI_VERSION_1_6 : JNI_ERR;
}

namespace {
struct AttachedEnv {
  struct ThreadAttachment {
    explicit ThreadAttachment(JavaVM *vm) : vm(vm) {
      if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        if (vm->AttachCurrentThread(&env, nullptr) == JNI_OK) attached = true;
      }
    }
    ~ThreadAttachment() { if (attached) vm->DetachCurrentThread(); }
    JavaVM *vm;
    JNIEnv *env = nullptr;
    bool attached = false;
  };
  explicit AttachedEnv(JavaVM *vm) {
    // Demux performs many short reads. Repeated attachment creates ART thread
    // state on every read/seek and adds GC pauses during 4K preroll. Native
    // workers attach once and detach at thread exit; Java-owned threads remain
    // owned by the VM. JNIEnv is never shared with a different thread.
    thread_local std::unique_ptr<ThreadAttachment> attachment;
    if (!attachment || attachment->vm != vm || !attachment->env)
      attachment = std::make_unique<ThreadAttachment>(vm);
    env = attachment->env;
  }
  JNIEnv *env = nullptr;
};

struct JavaTunnelSink final : AndroidTunnelSink {
  JavaVM* vm;
  jobject peer;
  jmethodID queue, rendered, close;
  JavaTunnelSink(JavaVM* vm, JNIEnv* env, jobject local) : vm(vm) {
    peer = env->NewGlobalRef(local);
    jclass cls = env->GetObjectClass(local);
    queue = env->GetMethodID(cls, "queue", "(Ljava/nio/ByteBuffer;J)I");
    rendered = env->GetMethodID(cls, "rendered", "()J");
    close = env->GetMethodID(cls, "close", "()V");
    env->DeleteLocalRef(cls);
  }
  ~JavaTunnelSink() override {
    AttachedEnv thread(vm);
    if (auto* env = thread.env) {
      env->CallVoidMethod(peer, close);
      if (env->ExceptionCheck()) env->ExceptionClear();
      env->DeleteGlobalRef(peer);
    }
  }
  int Queue(const uint8_t* data, int size, int64_t pts) override {
    AttachedEnv thread(vm); auto* env = thread.env;
    if (!env) return -1;
    jobject bytes = data ? env->NewDirectByteBuffer(const_cast<uint8_t*>(data), size) : nullptr;
    if (data && !bytes) { env->ExceptionClear(); return -1; }
    const int result = env->CallIntMethod(peer, queue, bytes, static_cast<jlong>(pts));
    if (bytes) env->DeleteLocalRef(bytes);
    if (env->ExceptionCheck()) { env->ExceptionClear(); return -1; }
    return result;
  }
  int64_t Rendered() override {
    AttachedEnv thread(vm); auto* env = thread.env;
    if (!env) return -1;
    const auto result = env->CallLongMethod(peer, rendered);
    if (env->ExceptionCheck()) { env->ExceptionClear(); return -1; }
    return result;
  }
};

struct JavaTunnelFactory final : AndroidTunnelFactory {
  JavaVM* vm;
  jobject peer;
  jmethodID open;
  JavaTunnelFactory(JNIEnv* env, jobject local) {
    env->GetJavaVM(&vm); peer = env->NewGlobalRef(local);
    jclass cls = env->GetObjectClass(local);
    open = env->GetMethodID(cls, "open",
        "(Landroid/view/Surface;IIIILjava/nio/ByteBuffer;Ljava/nio/ByteBuffer;I)Lcom/rillight/player/CoreTunnelDecoder;");
    env->DeleteLocalRef(cls);
  }
  ~JavaTunnelFactory() override {
    AttachedEnv thread(vm);
    if (thread.env) thread.env->DeleteGlobalRef(peer);
  }
  std::shared_ptr<AndroidTunnelSink> Open(void* window, int width, int height,
      int profile, int level, const std::vector<uint8_t>& csd,
      const std::vector<uint8_t>& config, int rate) override {
    AttachedEnv thread(vm); auto* env = thread.env;
    if (!env || !open) return {};
    using ToSurface = jobject (*)(JNIEnv*, ANativeWindow*);
    static const auto to_surface = reinterpret_cast<ToSurface>(dlsym(RTLD_DEFAULT, "ANativeWindow_toSurface"));
    jobject surface = to_surface ? to_surface(env, static_cast<ANativeWindow*>(window)) : nullptr;
    jobject init = env->NewDirectByteBuffer(const_cast<uint8_t*>(csd.data()), csd.size());
    jobject dv = env->NewDirectByteBuffer(const_cast<uint8_t*>(config.data()), config.size());
    jobject sink = surface && init && dv ? env->CallObjectMethod(peer, open,
        surface, width, height, profile, level, init, dv, rate) : nullptr;
    if (env->ExceptionCheck()) { env->ExceptionClear(); sink = nullptr; }
    if (surface) env->DeleteLocalRef(surface);
    if (init) env->DeleteLocalRef(init);
    if (dv) env->DeleteLocalRef(dv);
    std::shared_ptr<AndroidTunnelSink> result;
    if (sink) { result = std::make_shared<JavaTunnelSink>(vm, env, sink); env->DeleteLocalRef(sink); }
    return result;
  }
};

struct Source {
  Source(JavaVM *vm, jobject object) : vm(vm), object(object) {}
  ~Source() {
    AttachedEnv thread(vm);
    if (thread.env) {
      if (read_buffer) thread.env->DeleteGlobalRef(read_buffer);
      thread.env->DeleteGlobalRef(object);
    }
  }
  JavaVM *vm;
  jobject object;
  // AVIO permits short reads. Reuse bounded storage instead of allocating a
  // Java array sized to each large demux request and provoking loading GC.
  static constexpr int kReadBufferBytes = 64 * 1024;
  std::mutex read_mutex;
  jbyteArray read_buffer = nullptr;
  bool media = false;
};

struct Bridge {
  JavaVM *vm = nullptr;
  jobject factory = nullptr;
  jmethodID open = nullptr;
  jmethodID read = nullptr;
  jmethodID seek = nullptr;
  jmethodID close = nullptr;
  jmethodID interrupt = nullptr;
  std::mutex sources_mutex;
  std::mutex presentation_mutex;
  std::vector<uint8_t> overlay;
  int overlay_geometry[6] = {};
  bool overlay_changed = false;
  std::unordered_map<Source *, std::shared_ptr<Source>> sources;
  MediaIoRoles roles;
  RillightCore *core = nullptr;

  ~Bridge() {
    rillight_core_destroy(core);
    std::vector<std::shared_ptr<Source>> remaining;
    {
      std::lock_guard lock(sources_mutex);
      for (auto &entry : sources) remaining.push_back(entry.second);
      sources.clear();
    }
    AttachedEnv thread(vm);
    if (thread.env) {
      for (auto &source : remaining) {
        thread.env->CallVoidMethod(source->object, close);
        if (thread.env->ExceptionCheck()) thread.env->ExceptionClear();
      }
      thread.env->DeleteGlobalRef(factory);
    }
  }

  std::shared_ptr<Source> find(void *raw) {
    std::lock_guard lock(sources_mutex);
    auto it = sources.find(static_cast<Source *>(raw));
    return it == sources.end() ? nullptr : it->second;
  }

  static void *open_source(void *opaque, const char *url, int) {
    auto *bridge = static_cast<Bridge *>(opaque);
    AttachedEnv thread(bridge->vm);
    if (!thread.env) return nullptr;
    jstring address = thread.env->NewStringUTF(url);
    jobject local = thread.env->CallObjectMethod(bridge->factory, bridge->open,
                                                address);
    thread.env->DeleteLocalRef(address);
    if (thread.env->ExceptionCheck()) {
      thread.env->ExceptionClear();
      return nullptr;
    }
    if (!local) return nullptr;
    jobject global = thread.env->NewGlobalRef(local);
    thread.env->DeleteLocalRef(local);
    if (!global) return nullptr;
    auto source = std::make_shared<Source>(bridge->vm, global);
    auto *raw = source.get();
    {
      std::lock_guard lock(bridge->sources_mutex);
      source->media = bridge->roles.is_media(std::this_thread::get_id());
      bridge->sources.emplace(raw, std::move(source));
    }
    return raw;
  }

  static int read_source(void *opaque, void *raw, uint8_t *data, int size) {
    auto *bridge = static_cast<Bridge *>(opaque);
    auto source = bridge->find(raw);
    if (!source || size <= 0) return -EINVAL;
    AttachedEnv thread(bridge->vm);
    if (!thread.env) return -EIO;
    std::lock_guard read_lock(source->read_mutex);
    size = std::min(size, Source::kReadBufferBytes);
    if (!source->read_buffer) {
      auto local = thread.env->NewByteArray(Source::kReadBufferBytes);
      if (local) {
        source->read_buffer = static_cast<jbyteArray>(thread.env->NewGlobalRef(local));
        thread.env->DeleteLocalRef(local);
      }
      if (!source->read_buffer) {
        if (thread.env->ExceptionCheck()) thread.env->ExceptionClear();
        return -ENOMEM;
      }
    }
    jbyteArray buffer = source->read_buffer;
    jint count = thread.env->CallIntMethod(source->object, bridge->read, buffer,
                                          static_cast<jint>(size));
    if (thread.env->ExceptionCheck()) {
      thread.env->ExceptionClear();
      count = -EIO;
    }
    if (count > size) count = -EIO;
    if (count > 0)
      thread.env->GetByteArrayRegion(buffer, 0, count,
                                     reinterpret_cast<jbyte *>(data));
    if (thread.env->ExceptionCheck()) {
      thread.env->ExceptionClear();
      return -EIO;
    }
    return count;
  }

  static int64_t seek_source(void *opaque, void *raw, int64_t offset, int whence) {
    auto *bridge = static_cast<Bridge *>(opaque);
    auto source = bridge->find(raw);
    if (!source) return -EINVAL;
    AttachedEnv thread(bridge->vm);
    if (!thread.env) return -EIO;
    jlong position = thread.env->CallLongMethod(source->object, bridge->seek,
                                               static_cast<jlong>(offset), whence);
    if (thread.env->ExceptionCheck()) {
      thread.env->ExceptionClear();
      return -EIO;
    }
    return position;
  }

  static void close_source(void *opaque, void *raw) {
    auto *bridge = static_cast<Bridge *>(opaque);
    std::shared_ptr<Source> source;
    {
      std::lock_guard lock(bridge->sources_mutex);
      auto it = bridge->sources.find(static_cast<Source *>(raw));
      if (it == bridge->sources.end()) return;
      source = std::move(it->second);
      bridge->sources.erase(it);
    }
    AttachedEnv thread(bridge->vm);
    if (thread.env) {
      thread.env->CallVoidMethod(source->object, bridge->close);
      if (thread.env->ExceptionCheck()) thread.env->ExceptionClear();
    }
  }

  static void signal(void *opaque, bool media_only) {
    auto *bridge = static_cast<Bridge *>(opaque);
    std::vector<std::shared_ptr<Source>> selected;
    {
      std::lock_guard lock(bridge->sources_mutex);
      for (auto &entry : bridge->sources)
        if (!media_only || entry.second->media)
          selected.push_back(entry.second);
    }
    AttachedEnv thread(bridge->vm);
    if (!thread.env) return;
    for (auto &source : selected) {
      thread.env->CallVoidMethod(source->object, bridge->interrupt);
      if (thread.env->ExceptionCheck()) thread.env->ExceptionClear();
    }
  }
  static void cancel(void *opaque) { signal(opaque, false); }
  static void cancel_media(void *opaque) { signal(opaque, true); }
};

Bridge *bridge(jlong handle) { return reinterpret_cast<Bridge *>(handle); }

jlongArray numbers(JNIEnv *env, const jlong *values, jsize count) {
  auto result = env->NewLongArray(count);
  if (result) env->SetLongArrayRegion(result, 0, count, values);
  return result;
}
}  // namespace

extern "C" {
JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_abiVersion(JNIEnv *, jobject) {
  return static_cast<jint>(rillight_core_abi_version());
}

JNIEXPORT jboolean JNICALL
Java_com_rillight_player_CoreNative_hasDecoder(JNIEnv *env, jobject, jstring name) {
  if (!name) return JNI_FALSE;
  const char *utf = env->GetStringUTFChars(name, nullptr);
  if (!utf) return JNI_FALSE;
  const int found = rillight_core_has_decoder(utf);
  env->ReleaseStringUTFChars(name, utf);
  return found == 1 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jlong JNICALL
Java_com_rillight_player_CoreNative_create(JNIEnv *env, jobject, jobject factory) {
  if (!factory || rillight_core_abi_version() != RILLIGHT_CORE_ABI_VERSION) return 0;
  auto owner = std::make_unique<Bridge>();
  env->GetJavaVM(&owner->vm);
  owner->factory = env->NewGlobalRef(factory);
  jclass factory_class = env->GetObjectClass(factory);
  jclass input_class = env->FindClass("com/rillight/player/CoreInput");
  if (!factory_class || !input_class || !owner->factory) return 0;
  owner->open = env->GetMethodID(factory_class, "open", "(Ljava/lang/String;)Lcom/rillight/player/CoreInput;");
  owner->read = env->GetMethodID(input_class, "read", "([BI)I");
  owner->seek = env->GetMethodID(input_class, "seek", "(JI)J");
  owner->close = env->GetMethodID(input_class, "close", "()V");
  owner->interrupt = env->GetMethodID(input_class, "interrupt", "()V");
  env->DeleteLocalRef(factory_class);
  env->DeleteLocalRef(input_class);
  if (!owner->open || !owner->read || !owner->seek || !owner->close ||
      !owner->interrupt) return 0;
  RillightCoreIo io{};
  io.opaque = owner.get();
  io.open = Bridge::open_source;
  io.read = Bridge::read_source;
  io.seek = Bridge::seek_source;
  io.close = Bridge::close_source;
  io.cancel = Bridge::cancel;
  io.cancel_media_io = Bridge::cancel_media;
  owner->core = rillight_core_create(&io);
  if (!owner->core) return 0;
  return reinterpret_cast<jlong>(owner.release());
}

JNIEXPORT void JNICALL
Java_com_rillight_player_CoreNative_destroy(JNIEnv *, jobject, jlong handle) {
  delete bridge(handle);
}

JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_configureHardware(
    JNIEnv *, jobject, jlong handle, jint preference, jboolean fallback) {
  if (!handle || (preference != RILLIGHT_CORE_HW_NONE &&
                  preference != RILLIGHT_CORE_HW_MEDIACODEC)) return -1;
  auto *owner = bridge(handle);
  std::lock_guard lock(owner->presentation_mutex);
  return rillight_core_configure_hardware(
      owner->core, static_cast<RillightCoreHardware>(preference), fallback ? 1 : 0);
}

JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_videoOutputSize(
    JNIEnv *, jobject, jlong handle, jint width, jint height) {
  return handle ? rillight_core_set_video_output_size(
      bridge(handle)->core, width, height) : -1;
}

JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_open(JNIEnv *env, jobject, jlong handle,
                                        jstring address, jlong position,
                                        jlong operation) {
  if (!handle || !address) return -1;
  const char *url = env->GetStringUTFChars(address, nullptr);
  auto *owner = bridge(handle);
  std::lock_guard lock(owner->presentation_mutex);
  int result = rillight_core_open_at(owner->core, url, position, operation);
  env->ReleaseStringUTFChars(address, url);
  return result;
}

JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_play(JNIEnv *, jobject, jlong handle,
                                        jboolean playing, jlong operation) {
  return handle ? rillight_core_set_playing(bridge(handle)->core, playing,
                                            operation) : -1;
}
JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_seek(JNIEnv *, jobject, jlong handle,
                                        jlong position, jlong operation) {
  if (!handle) return -1;
  auto *owner = bridge(handle);
  std::lock_guard lock(owner->presentation_mutex);
  return rillight_core_seek(owner->core, position, operation);
}
JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_speed(JNIEnv *, jobject, jlong handle,
                                         jdouble speed, jlong operation) {
  if (!handle) return -1;
  auto *owner = bridge(handle);
  std::lock_guard lock(owner->presentation_mutex);
  return rillight_core_set_speed(owner->core, speed, operation);
}
JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_configureExternalAudioSpeed(
    JNIEnv *, jobject, jlong handle, jboolean enabled) {
  return handle ? rillight_core_configure_external_audio_speed(
      bridge(handle)->core, enabled == JNI_TRUE) : -1;
}
JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_configureAudioSink(
    JNIEnv *, jobject, jlong handle, jint channels, jint accepted, jboolean atmos) {
  if (!handle) return -1;
  RillightCoreAudioSink sink{};
  sink.struct_size = sizeof(sink);
  sink.max_pcm_channels = channels;
  sink.accepted_passthrough = static_cast<uint32_t>(accepted);
  sink.reports_atmos = atmos == JNI_TRUE ? 1 : 0;
  return rillight_core_configure_audio_sink(bridge(handle)->core, &sink);
}
JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_selectAudio(JNIEnv *, jobject, jlong handle,
                                               jint stream, jlong operation) {
  if (!handle) return -1;
  auto *owner = bridge(handle);
  std::lock_guard lock(owner->presentation_mutex);
  return rillight_core_select_audio(owner->core, stream, operation);
}
JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_selectSubtitle(JNIEnv *, jobject, jlong handle,
                                                  jint stream, jlong operation) {
  if (!handle) return -1;
  auto *owner = bridge(handle);
  std::lock_guard lock(owner->presentation_mutex);
  return rillight_core_select_subtitle(owner->core, stream, operation);
}
JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_addSubtitle(JNIEnv *env, jobject,
                                                jlong handle, jstring address,
                                                jlong operation) {
  if (!handle || !address) return -1;
  const char *url = env->GetStringUTFChars(address, nullptr);
  int result = rillight_core_add_external_subtitle(bridge(handle)->core, url,
                                                    operation);
  env->ReleaseStringUTFChars(address, url);
  return result;
}

// state, session, operation, timeline, error, video, audio, subtitle,
// duration, position, firstVideo, firstAudio, EOF, queuedVideo, queuedAudio,
// externalPending, speed * 1000, then the ABI 10 output fields in header order.
JNIEXPORT jlongArray JNICALL
Java_com_rillight_player_CoreNative_snapshot(JNIEnv *env, jobject, jlong handle) {
  if (!handle) return nullptr;
  RillightCoreSnapshot s{};
  s.struct_size = sizeof(s);
  if (rillight_core_snapshot(bridge(handle)->core, &s) != 0 ||
      s.abi_version != RILLIGHT_CORE_ABI_VERSION)
    return nullptr;
  const jlong values[] = {s.state, static_cast<jlong>(s.session_id),
      static_cast<jlong>(s.operation_id), static_cast<jlong>(s.timeline_version),
      s.ffmpeg_error, s.video_stream_index, s.audio_stream_index,
      s.subtitle_stream_index, s.duration_us, s.position_us,
      s.first_video_frame_ready, s.first_audio_frame_ready, s.source_eof,
      s.queued_video_frames, s.queued_audio_frames,
      s.external_subtitle_pending, static_cast<jlong>(s.playback_speed * 1000),
      s.dolby_vision_profile, s.video_output_kind, s.audio_delivery,
      s.audio_channels, s.audio_layout, s.audio_atmos, s.audio_codec_id,
      s.requested_interpolation, s.effective_interpolation,
      s.requested_anime4k, s.effective_anime4k,
      s.requested_super_resolution, s.effective_super_resolution,
      s.requested_denoise, s.effective_denoise,
      s.requested_sharpen, s.effective_sharpen,
      s.dovi_reconstruction, s.dolby_vision_compatibility};
  return numbers(env, values, sizeof(values) / sizeof(values[0]));
}

JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_subtitlePresentation(JNIEnv *, jobject,
    jlong handle, jlong session, jdouble width, jdouble height, jdouble font_size,
    jdouble scale, jboolean original, jdouble horizontal, jdouble vertical) {
  if (!handle) return -1;
  RillightCoreSubtitlePresentation p{sizeof(p), 1, 1, original ? 1 : 0,
      width, height, font_size, scale, horizontal, vertical};
  return rillight_core_set_subtitle_presentation(bridge(handle)->core, &p, session);
}

JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_trackCount(JNIEnv *, jobject, jlong handle) {
  return handle ? rillight_core_track_count(bridge(handle)->core) : -1;
}
JNIEXPORT jintArray JNICALL
Java_com_rillight_player_CoreNative_containerTrackIds(JNIEnv *env, jobject,
                                                     jlong handle) {
  if (!handle) return nullptr;
  int video = -1;
  int audio = -1;
  if (rillight_core_container_track_ids(bridge(handle)->core, &video,
                                        &audio) != 0) return nullptr;
  const jint ids[] = {video, audio};
  auto *result = env->NewIntArray(2);
  if (result) env->SetIntArrayRegion(result, 0, 2, ids);
  return result;
}
JNIEXPORT jintArray JNICALL
Java_com_rillight_player_CoreNative_track(JNIEnv *env, jobject, jlong handle,
                                         jint ordinal) {
  if (!handle) return nullptr;
  RillightCoreTrack track{};
  track.struct_size = sizeof(track);
  if (rillight_core_get_track(bridge(handle)->core, ordinal, &track) != 0)
    return nullptr;
  jint values[] = {track.stream_index, track.type, track.codec_id,
                   static_cast<jint>(track.decoder_hardware_capabilities),
                   static_cast<jint>(track.actual_hardware), track.is_external,
                   rillight_core_has_decoder(track.codec_name)};
  jintArray result = env->NewIntArray(7);
  if (result) env->SetIntArrayRegion(result, 0, 7, values);
  return result;
}
JNIEXPORT jstring JNICALL
Java_com_rillight_player_CoreNative_trackLanguage(JNIEnv *env, jobject,
                                                 jlong handle, jint ordinal) {
  if (!handle) return nullptr;
  RillightCoreTrack track{};
  track.struct_size = sizeof(track);
  if (rillight_core_get_track(bridge(handle)->core, ordinal, &track) != 0)
    return nullptr;
  return env->NewStringUTF(track.language);
}

JNIEXPORT jobject JNICALL
Java_com_rillight_player_CoreNative_takeAudio(JNIEnv *env, jobject,
                                             jlong handle) {
  if (!handle) return nullptr;
  auto *core = bridge(handle)->core;
  RillightCoreSnapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  if (rillight_core_snapshot(core, &snapshot) != 0) return nullptr;
  RillightCoreFrame *frame = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16);
  if (!frame) return nullptr;
  if (frame->session_id != snapshot.session_id ||
      frame->timeline_version != snapshot.timeline_version) {
    rillight_core_release_frame(frame);
    return nullptr;
  }
  jbyteArray bytes = env->NewByteArray(frame->data_size);
  if (bytes) env->SetByteArrayRegion(bytes, 0, frame->data_size,
                                    reinterpret_cast<const jbyte *>(frame->data));
  jclass cls = env->FindClass("com/rillight/player/CoreAudioFrame");
  jmethodID ctor = cls ? env->GetMethodID(cls, "<init>", "(JJJ[BIIIZI)V") : nullptr;
  jobject result = bytes && ctor ? env->NewObject(cls, ctor,
      static_cast<jlong>(frame->session_id),
      static_cast<jlong>(frame->timeline_version),
      static_cast<jlong>(frame->pts_us), bytes,
      frame->channels, frame->sample_count, frame->audio_delivery,
      frame->type == RILLIGHT_CORE_AUDIO_PASSTHROUGH ? JNI_TRUE : JNI_FALSE,
      frame->audio_codec_id) : nullptr;
  if (cls) env->DeleteLocalRef(cls);
  if (bytes) env->DeleteLocalRef(bytes);
  rillight_core_release_frame(frame);
  return result;
}

JNIEXPORT jlongArray JNICALL
Java_com_rillight_player_CoreNative_renderVideo(JNIEnv *env, jobject,
                                               jlong handle, jobject surface,
                                               jboolean hdr_supported) {
  if (!handle || !surface) return nullptr;
  ANativeWindow *window = ANativeWindow_fromSurface(env, surface);
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    return nullptr;
  }
  if (!window) return nullptr;
  auto *core = bridge(handle)->core;
  RillightCoreSnapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  if (rillight_core_snapshot(core, &snapshot) != 0) {
    ANativeWindow_release(window);
    return nullptr;
  }
  RillightCoreFrame *frame = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_MEDIACODEC);
  if (!frame) { ANativeWindow_release(window); return nullptr; }
  if (frame->session_id != snapshot.session_id ||
      frame->timeline_version != snapshot.timeline_version ||
      frame->width <= 0 || frame->height <= 0 ||
      (frame->type == RILLIGHT_CORE_VIDEO_RGBA && frame->stride < frame->width * 4)) {
    rillight_core_release_frame(frame);
    ANativeWindow_release(window);
    return nullptr;
  }
  if (frame->type == RILLIGHT_CORE_VIDEO_RGBA) {
  const int geometry = ANativeWindow_getWidth(window) == frame->width &&
          ANativeWindow_getHeight(window) == frame->height &&
          ANativeWindow_getFormat(window) == WINDOW_FORMAT_RGBA_8888
      ? 0 : ANativeWindow_setBuffersGeometry(
                window, frame->width, frame->height, WINDOW_FORMAT_RGBA_8888);
  ANativeWindow_Buffer buffer{};
  const int locked = geometry == 0 ? ANativeWindow_lock(window, &buffer, nullptr) : -1;
  if (locked != 0 || !buffer.bits || buffer.width <= 0 || buffer.height <= 0 ||
      buffer.stride < buffer.width) {
    if (locked == 0) ANativeWindow_unlockAndPost(window);
    rillight_core_release_frame(frame);
    ANativeWindow_release(window);
    return nullptr;
  }
  auto *pixels = static_cast<uint8_t *>(buffer.bits);
  if (!CopyRgbaSurface(
          {frame->data, frame->width, frame->height, static_cast<size_t>(frame->stride)},
          {pixels, buffer.width, buffer.height, static_cast<size_t>(buffer.stride) * 4})) {
    ANativeWindow_unlockAndPost(window);
    rillight_core_release_frame(frame);
    ANativeWindow_release(window);
    return nullptr;
  }
  bool current = false;
  int posted = -1;
  {
    std::lock_guard lock(bridge(handle)->presentation_mutex);
    RillightCoreSnapshot latest{};
    latest.struct_size = sizeof(latest);
    current = rillight_core_snapshot(core, &latest) == 0 &&
              latest.session_id == frame->session_id &&
              latest.timeline_version == frame->timeline_version;
    if (!current) {
      for (int y = 0; y < buffer.height; ++y)
        std::memset(pixels + static_cast<size_t>(y) * buffer.stride * 4, 0,
                    static_cast<size_t>(buffer.stride) * 4);
    }
    posted = ANativeWindow_unlockAndPost(window);
  }
  ANativeWindow_release(window);
  if (!current || posted != 0) {
    rillight_core_release_frame(frame);
    return nullptr;
  }
  } else {
    std::lock_guard lock(bridge(handle)->presentation_mutex);
    RillightCoreSnapshot latest{};
    latest.struct_size = sizeof(latest);
    const bool current = rillight_core_snapshot(core, &latest) == 0 &&
        latest.session_id == frame->session_id && latest.timeline_version == frame->timeline_version;
    const int rendered = !current ? -1 : frame->type == RILLIGHT_CORE_VIDEO_ANDROID_P010
        ? rillight_core_render_android_color_frame(frame, window, hdr_supported == JNI_TRUE, core)
        : frame->type == RILLIGHT_CORE_VIDEO_ANDROID_TUNNEL ? 0
        : rillight_core_render_mediacodec_frame(frame);
    if (current && rillight_core_report_android_presentation(core, frame, rendered == 0) == 1)
      rillight_core_release_android_color_renderer();
    ANativeWindow_release(window);
    if (rendered != 0) {
      rillight_core_release_frame(frame);
      return nullptr;
    }
  }
  {
    std::lock_guard lock(bridge(handle)->presentation_mutex);
    auto* owner = bridge(handle);
    RillightCoreSubtitleOverlay plane{};
    plane.struct_size = sizeof(plane);
    const bool present = rillight_core_frame_subtitle_overlay(frame, &plane) == 0 && plane.data;
    const int geometry[] = {plane.x, plane.y, plane.width, plane.height, frame->width, frame->height};
    const size_t bytes = present ? static_cast<size_t>(plane.stride) * plane.height : 0;
    const bool changed = !std::equal(std::begin(geometry), std::end(geometry), owner->overlay_geometry) ||
        owner->overlay.size() != bytes || (bytes && std::memcmp(owner->overlay.data(), plane.data, bytes));
    if (changed) {
      std::copy(std::begin(geometry), std::end(geometry), owner->overlay_geometry);
      if (bytes) owner->overlay.assign(plane.data, plane.data + bytes);
      else owner->overlay.clear();
      owner->overlay_changed = true;
    }
  }
  // FFmpeg's display matrix uses 16.16 fixed point for the first two rows.
  int rotation = 0;
  if (frame->has_display_matrix) {
    const int32_t *m = frame->display_matrix;
    if (m[0] == 0 && m[4] == 0) rotation = m[1] > 0 ? 90 : 270;
    else if (m[0] < 0 && m[4] < 0) rotation = 180;
  }
  const jlong values[] = {frame->pts_us, frame->width, frame->height,
                          frame->sar_num, frame->sar_den, rotation,
                          static_cast<jlong>(frame->session_id),
                          static_cast<jlong>(frame->timeline_version),
                          frame->source_color_transfer, frame->source_color_primaries};
  auto *result = numbers(env, values, sizeof(values) / sizeof(values[0]));
  rillight_core_release_frame(frame);
  return result;
}

JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_configureTunnel(JNIEnv* env, jobject,
    jlong handle, jobject factory, jint profiles) {
  if (!handle) return -1;
  auto peer = factory ? std::make_shared<JavaTunnelFactory>(env, factory) : nullptr;
  if (env->ExceptionCheck()) { env->ExceptionClear(); return -1; }
  return rillight_core_android_tunnel_factory(bridge(handle)->core, peer, profiles);
}

JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_outputSurface(JNIEnv* env, jobject,
                                                 jlong handle, jobject surface,
                                                 jint dovi_profiles) {
  if (!handle) return -1;
  ANativeWindow* window = surface ? ANativeWindow_fromSurface(env, surface) : nullptr;
  if (env->ExceptionCheck()) { env->ExceptionClear(); return -1; }
  std::lock_guard lock(bridge(handle)->presentation_mutex);
  const int code = rillight_core_set_android_window(bridge(handle)->core, window,
      static_cast<uint32_t>(dovi_profiles));
  if (window) ANativeWindow_release(window);
  return code;
}

JNIEXPORT void JNICALL
Java_com_rillight_player_CoreNative_releaseColorRenderer(JNIEnv*, jobject) {
  rillight_core_release_android_color_renderer();
}

JNIEXPORT jdouble JNICALL
Java_com_rillight_player_CoreNative_videoFrameRate(JNIEnv*, jobject, jlong handle) {
  return handle ? rillight_core_video_frame_rate(bridge(handle)->core) : 0;
}

JNIEXPORT jdouble JNICALL
Java_com_rillight_player_CoreNative_outputFrameRate(JNIEnv*, jobject, jlong handle) {
  return handle ? rillight_core_output_frame_rate(bridge(handle)->core) : 0;
}

namespace {

int apply_enhancement_jni(jlong handle, jint interpolation, jint anime4k,
                          jint super_resolution, jint denoise, jint sharpen,
                          jint accept_leave, jint refresh_hz, bool retry) {
  if (!handle) return -1;
  RillightCoreEnhancementRequest request{};
  request.struct_size = sizeof(request);
  request.interpolation = interpolation;
  request.anime4k = anime4k;
  request.super_resolution = super_resolution;
  request.denoise = denoise;
  request.sharpen = sharpen;
  request.accept_leave_native_dolby = accept_leave;
  request.display_refresh_hz = refresh_hz;
  auto* owner = bridge(handle);
  std::lock_guard lock(owner->presentation_mutex);
  return retry ? rillight_core_retry_enhancement(owner->core, &request)
               : rillight_core_configure_enhancement(owner->core, &request);
}

}  // namespace

JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_configureEnhancement(
    JNIEnv*, jobject, jlong handle, jint interpolation, jint anime4k,
    jint super_resolution, jint denoise, jint sharpen, jint accept_leave,
    jint refresh_hz) {
  return apply_enhancement_jni(handle, interpolation, anime4k, super_resolution,
                               denoise, sharpen, accept_leave, refresh_hz,
                               false);
}

JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_retryEnhancement(
    JNIEnv*, jobject, jlong handle, jint interpolation, jint anime4k,
    jint super_resolution, jint denoise, jint sharpen, jint accept_leave,
    jint refresh_hz) {
  return apply_enhancement_jni(handle, interpolation, anime4k, super_resolution,
                               denoise, sharpen, accept_leave, refresh_hz,
                               true);
}

JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_noteFrameDeadline(
    JNIEnv*, jobject, jlong handle, jint met, jlong monotonic_us) {
  if (!handle) return -1;
  auto* owner = bridge(handle);
  std::lock_guard lock(owner->presentation_mutex);
  return rillight_core_note_frame_deadline(owner->core, met, monotonic_us);
}

JNIEXPORT jintArray JNICALL
Java_com_rillight_player_CoreNative_enhancementStatus(JNIEnv* env, jobject,
                                                     jlong handle) {
  if (!handle) return nullptr;
  RillightCoreEnhancementStatus status{};
  status.struct_size = sizeof(status);
  if (rillight_core_enhancement_status(bridge(handle)->core, &status) != 0)
    return nullptr;
  const jint values[] = {
      status.requested_interpolation, status.effective_interpolation,
      status.requested_anime4k, status.effective_anime4k,
      status.requested_super_resolution, status.effective_super_resolution,
      status.requested_denoise, status.effective_denoise,
      status.requested_sharpen, status.effective_sharpen,
      status.reason_interpolation, status.reason_anime4k,
      status.reason_super_resolution, status.reason_denoise,
      status.reason_sharpen, status.interpolation_backend,
      status.anime4k_backend, status.super_resolution_backend,
      status.left_native_dolby};
  auto* result = env->NewIntArray(19);
  if (result) env->SetIntArrayRegion(result, 0, 19, values);
  return result;
}

JNIEXPORT jobject JNICALL
Java_com_rillight_player_CoreNative_takeVideoOverlay(JNIEnv* env, jobject, jlong handle) {
  if (!handle) return nullptr;
  auto* owner = bridge(handle);
  std::lock_guard lock(owner->presentation_mutex);
  if (!owner->overlay_changed) return nullptr;
  jbyteArray bytes = env->NewByteArray(static_cast<jsize>(owner->overlay.size()));
  if (bytes && !owner->overlay.empty())
    env->SetByteArrayRegion(bytes, 0, static_cast<jsize>(owner->overlay.size()),
        reinterpret_cast<const jbyte*>(owner->overlay.data()));
  jclass cls = env->FindClass("com/rillight/player/CoreVideoOverlay");
  jmethodID ctor = cls ? env->GetMethodID(cls, "<init>", "(IIIIII[B)V") : nullptr;
  const int* g = owner->overlay_geometry;
  jobject result = bytes && ctor ? env->NewObject(cls, ctor, g[0], g[1], g[2], g[3], g[4], g[5], bytes) : nullptr;
  if (cls) env->DeleteLocalRef(cls);
  if (bytes) env->DeleteLocalRef(bytes);
  if (result) owner->overlay_changed = false;
  return result;
}

JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_reportAudio(JNIEnv *, jobject, jlong handle,
                                               jlong session, jlong timeline,
                                               jlong played_pts, jlong delay) {
  return handle ? rillight_core_report_audio_played(bridge(handle)->core, session,
              timeline, played_pts, delay) : -1;
}

JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_reportAudioUnavailable(
    JNIEnv *, jobject, jlong handle, jlong session, jlong timeline) {
  return handle ? rillight_core_report_audio_unavailable(
                      bridge(handle)->core, session, timeline)
                : -1;
}

JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_reportDrained(JNIEnv *, jobject, jlong handle,
                                                 jlong session, jlong timeline) {
  return handle ? rillight_core_report_output_drained(bridge(handle)->core,
                        session, timeline) : -1;
}
}
