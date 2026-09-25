#include "../../core/rillight_core.h"

#include <cstdio>
#include <cstring>
#include <new>
#include <string>

namespace {
struct SmokeSession {
  std::string path;
  RillightCore* core = nullptr;
};

void* Open(void* opaque, const char* url, int) {
  auto* session = static_cast<SmokeSession*>(opaque);
  if (!url || session->path != url) return nullptr;
  return std::fopen(url, "rb");
}

int Read(void*, void* handle, uint8_t* bytes, int size) {
  auto* file = static_cast<FILE*>(handle);
  if (!file || !bytes || size <= 0) return -1;
  const size_t count = std::fread(bytes, 1, static_cast<size_t>(size), file);
  return count > 0 ? static_cast<int>(count) : std::ferror(file) ? -5 : 0;
}

int64_t Seek(void*, void* handle, int64_t offset, int whence) {
  auto* file = static_cast<FILE*>(handle);
  if (!file) return -1;
  if (whence == 0x10000) {
    const auto previous = _ftelli64(file);
    if (_fseeki64(file, 0, SEEK_END) != 0) return -1;
    const auto size = _ftelli64(file);
    _fseeki64(file, previous, SEEK_SET);
    return size;
  }
  if (_fseeki64(file, offset, whence & 0xffff) != 0) return -1;
  return _ftelli64(file);
}

void Close(void*, void* handle) {
  if (handle) std::fclose(static_cast<FILE*>(handle));
}

void Cancel(void*) {}
}  // namespace

extern "C" __declspec(dllexport) SmokeSession* t4_smoke_create(
    const char* path) {
  if (!path || !*path) return nullptr;
  auto* session = new (std::nothrow) SmokeSession();
  if (!session) return nullptr;
  session->path = path;
  RillightCoreIo io{session, Open, Read, Seek, Close, Cancel, Cancel};
  session->core = rillight_core_create(&io);
  if (!session->core ||
      rillight_core_configure_hardware(session->core, RILLIGHT_CORE_HW_D3D11,
                                       1) != 0 ||
      rillight_core_open(session->core, session->path.c_str(), 1) != 0) {
    if (session->core) rillight_core_destroy(session->core);
    delete session;
    return nullptr;
  }
  return session;
}

extern "C" __declspec(dllexport) RillightCore* t4_smoke_core(
    SmokeSession* session) {
  return session ? session->core : nullptr;
}

extern "C" __declspec(dllexport) int t4_smoke_try_play(
    SmokeSession* session) {
  if (!session) return -1;
  RillightCoreSnapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  if (rillight_core_snapshot(session->core, &snapshot) != 0) return -1;
  if (snapshot.state == RILLIGHT_CORE_PLAYING) return 1;
  if (snapshot.state != RILLIGHT_CORE_READY) return 0;
  return rillight_core_set_playing(session->core, 1, 2) == 0 ? 1 : -1;
}

extern "C" __declspec(dllexport) int64_t t4_smoke_position(
    SmokeSession* session) {
  if (!session) return -1;
  RillightCoreSnapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  if (rillight_core_snapshot(session->core, &snapshot) != 0) return -1;
  return snapshot.position_us;
}

extern "C" __declspec(dllexport) int t4_smoke_audio_ready(
    SmokeSession* session) {
  if (!session) return -1;
  RillightCoreSnapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  if (rillight_core_snapshot(session->core, &snapshot) != 0) return -1;
  return snapshot.first_audio_frame_ready;
}

extern "C" __declspec(dllexport) void t4_smoke_destroy(
    SmokeSession* session) {
  if (!session) return;
  rillight_core_destroy(session->core);
  delete session;
}
