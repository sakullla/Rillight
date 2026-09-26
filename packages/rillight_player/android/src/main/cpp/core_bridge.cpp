#include <jni.h>
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
#include "media_io_roles.h"

namespace {
struct AttachedEnv {
  explicit AttachedEnv(JavaVM *vm) : vm(vm) {
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
      if (vm->AttachCurrentThread(&env, nullptr) == JNI_OK) attached = true;
    }
  }
  ~AttachedEnv() { if (attached) vm->DetachCurrentThread(); }
  JavaVM *vm;
  JNIEnv *env = nullptr;
  bool attached = false;
};

struct Source {
  Source(JavaVM *vm, jobject object) : vm(vm), object(object) {}
  ~Source() {
    AttachedEnv thread(vm);
    if (thread.env) thread.env->DeleteGlobalRef(object);
  }
  JavaVM *vm;
  jobject object;
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
    jbyteArray buffer = thread.env->NewByteArray(size);
    if (!buffer) return -ENOMEM;
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
    thread.env->DeleteLocalRef(buffer);
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
Java_com_rillight_player_CoreNative_open(JNIEnv *env, jobject, jlong handle,
                                        jstring address, jlong operation) {
  if (!handle || !address) return -1;
  const char *url = env->GetStringUTFChars(address, nullptr);
  auto *owner = bridge(handle);
  std::lock_guard lock(owner->presentation_mutex);
  int result = rillight_core_open(owner->core, url, operation);
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
// externalPending, speed * 1000.
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
      s.external_subtitle_pending, static_cast<jlong>(s.playback_speed * 1000)};
  return numbers(env, values, sizeof(values) / sizeof(values[0]));
}

JNIEXPORT jint JNICALL
Java_com_rillight_player_CoreNative_trackCount(JNIEnv *, jobject, jlong handle) {
  return handle ? rillight_core_track_count(bridge(handle)->core) : -1;
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
                   static_cast<jint>(track.actual_hardware), track.is_external};
  jintArray result = env->NewIntArray(6);
  if (result) env->SetIntArrayRegion(result, 0, 6, values);
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
  jmethodID ctor = cls ? env->GetMethodID(cls, "<init>", "(JJJ[B)V") : nullptr;
  jobject result = bytes && ctor ? env->NewObject(cls, ctor,
      static_cast<jlong>(frame->session_id),
      static_cast<jlong>(frame->timeline_version),
      static_cast<jlong>(frame->pts_us), bytes) : nullptr;
  if (cls) env->DeleteLocalRef(cls);
  if (bytes) env->DeleteLocalRef(bytes);
  rillight_core_release_frame(frame);
  return result;
}

JNIEXPORT jlongArray JNICALL
Java_com_rillight_player_CoreNative_renderVideo(JNIEnv *env, jobject,
                                               jlong handle, jobject surface) {
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
  RillightCoreFrame *frame = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
  if (!frame) { ANativeWindow_release(window); return nullptr; }
  if (frame->session_id != snapshot.session_id ||
      frame->timeline_version != snapshot.timeline_version ||
      frame->width <= 0 || frame->height <= 0 ||
      frame->stride < frame->width * 4) {
    rillight_core_release_frame(frame);
    ANativeWindow_release(window);
    return nullptr;
  }
  const int geometry = ANativeWindow_getWidth(window) == frame->width &&
          ANativeWindow_getHeight(window) == frame->height &&
          ANativeWindow_getFormat(window) == WINDOW_FORMAT_RGBA_8888
      ? 0 : ANativeWindow_setBuffersGeometry(
                window, frame->width, frame->height, WINDOW_FORMAT_RGBA_8888);
  ANativeWindow_Buffer buffer{};
  const int locked = geometry == 0 ? ANativeWindow_lock(window, &buffer, nullptr) : -1;
  if (locked != 0 || !buffer.bits || buffer.stride < frame->width ||
      buffer.height < frame->height) {
    if (locked == 0) ANativeWindow_unlockAndPost(window);
    rillight_core_release_frame(frame);
    ANativeWindow_release(window);
    return nullptr;
  }
  auto *pixels = static_cast<uint8_t *>(buffer.bits);
  const size_t row = static_cast<size_t>(frame->width) * 4;
  for (int y = 0; y < frame->height; ++y)
    std::memcpy(pixels + static_cast<size_t>(y) * buffer.stride * 4,
                frame->data + static_cast<size_t>(y) * frame->stride, row);
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
                          static_cast<jlong>(frame->timeline_version)};
  auto *result = numbers(env, values, sizeof(values) / sizeof(values[0]));
  rillight_core_release_frame(frame);
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
