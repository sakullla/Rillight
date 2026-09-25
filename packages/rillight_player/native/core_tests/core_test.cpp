#include "../core/rillight_core.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

namespace {
struct Bytes {
  std::vector<uint8_t> data;
  size_t offset = 0;
};

struct Media {
  Bytes wav;
  Bytes bmp;
};

struct Blocking {
  std::mutex mutex;
  std::condition_variable wake;
  bool cancelled = false;
};

void append16(std::vector<uint8_t> &data, uint16_t value) {
  data.push_back(static_cast<uint8_t>(value));
  data.push_back(static_cast<uint8_t>(value >> 8));
}

void append32(std::vector<uint8_t> &data, uint32_t value) {
  append16(data, static_cast<uint16_t>(value));
  append16(data, static_cast<uint16_t>(value >> 16));
}

Bytes make_wav() {
  Bytes bytes;
  auto &data = bytes.data;
  const uint32_t samples = 4800;
  const uint32_t payload = samples * 2;
  data.insert(data.end(), {'R', 'I', 'F', 'F'});
  append32(data, 36 + payload);
  data.insert(data.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
  append32(data, 16);
  append16(data, 1);
  append16(data, 1);
  append32(data, 48000);
  append32(data, 48000 * 2);
  append16(data, 2);
  append16(data, 16);
  data.insert(data.end(), {'d', 'a', 't', 'a'});
  append32(data, payload);
  for (uint32_t index = 0; index < samples; ++index) {
    // A non-silent fixed waveform proves the PCM decoder produced data.
    append16(data, static_cast<uint16_t>((index % 80) * 300));
  }
  return bytes;
}

Bytes make_bmp() {
  Bytes bytes;
  auto &data = bytes.data;
  constexpr uint32_t width = 32;
  constexpr uint32_t height = 32;
  constexpr uint32_t payload = width * height * 3;
  data.insert(data.end(), {'B', 'M'});
  append32(data, 54 + payload);
  append32(data, 0);
  append32(data, 54);
  append32(data, 40);
  append32(data, width);
  append32(data, height);
  append16(data, 1);
  append16(data, 24);
  append32(data, 0);
  append32(data, payload);
  append32(data, 0);
  append32(data, 0);
  append32(data, 0);
  append32(data, 0);
  for (uint32_t y = 0; y < height; ++y) {
    for (uint32_t x = 0; x < width; ++x) {
      data.push_back(static_cast<uint8_t>(x * 8));
      data.push_back(static_cast<uint8_t>(y * 8));
      data.push_back(200);
    }
  }
  return bytes;
}

void *open(void *opaque, const char *url, int) {
  auto *media = static_cast<Media *>(opaque);
  const bool image = std::strstr(url, ".bmp") != nullptr;
  auto *copy = new Bytes(image ? media->bmp : media->wav);
  copy->offset = 0;
  return copy;
}

int read(void *, void *handle, uint8_t *buffer, int size) {
  auto *bytes = static_cast<Bytes *>(handle);
  const size_t count = std::min(static_cast<size_t>(size),
                                bytes->data.size() - bytes->offset);
  if (!count) return 0;
  std::memcpy(buffer, bytes->data.data() + bytes->offset, count);
  bytes->offset += count;
  return static_cast<int>(count);
}

int64_t seek(void *, void *handle, int64_t offset, int whence) {
  auto *bytes = static_cast<Bytes *>(handle);
  if (whence == 0x10000) return static_cast<int64_t>(bytes->data.size());
  int64_t base = 0;
  if (whence == 1) base = static_cast<int64_t>(bytes->offset);
  if (whence == 2) base = static_cast<int64_t>(bytes->data.size());
  const int64_t target = base + offset;
  if (target < 0 || target > static_cast<int64_t>(bytes->data.size()))
    return -1;
  bytes->offset = static_cast<size_t>(target);
  return target;
}

void close(void *, void *handle) { delete static_cast<Bytes *>(handle); }

void *blocked_open(void *opaque, const char *, int) { return opaque; }

int blocked_read(void *opaque, void *, uint8_t *, int) {
  auto *blocking = static_cast<Blocking *>(opaque);
  std::unique_lock lock(blocking->mutex);
  blocking->wake.wait(lock, [&] { return blocking->cancelled; });
  return -1;
}

int64_t blocked_seek(void *, void *, int64_t, int) { return -1; }

void blocked_close(void *, void *) {}

void blocked_cancel(void *opaque) {
  auto *blocking = static_cast<Blocking *>(opaque);
  {
    std::lock_guard lock(blocking->mutex);
    blocking->cancelled = true;
  }
  blocking->wake.notify_all();
}

RillightCoreSnapshot snapshot(RillightCore *core) {
  RillightCoreSnapshot value{};
  value.struct_size = sizeof(value);
  assert(rillight_core_snapshot(core, &value) == 0);
  return value;
}

bool wait_for(RillightCore *core, bool (*predicate)(const RillightCoreSnapshot &)) {
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(5);
  while (std::chrono::steady_clock::now() < deadline) {
    if (predicate(snapshot(core))) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return false;
}
}  // namespace

int main() {
  assert(rillight_core_abi_version() == RILLIGHT_CORE_ABI_VERSION);
  const char *versions = rillight_core_ffmpeg_versions();
  assert(versions && std::strstr(versions, "avformat=") != nullptr);
  std::printf("loaded FFmpeg libraries: %s\n", versions);
  Media media{make_wav(), make_bmp()};
  RillightCoreIo io{&media, open, read, seek, close, nullptr};
  auto *core = rillight_core_create(&io);
  assert(core);
  assert(rillight_core_open(core, "synthetic.wav", 1) == 0);
  assert(wait_for(core, [](const auto &state) {
    return state.first_audio_frame_ready && state.audio_stream_index >= 0;
  }));
  auto before = snapshot(core);
  assert(before.video_stream_index < 0);
  assert(before.session_id == 1);
  assert(rillight_core_track_count(core) == 1);
  RillightCoreTrack track{};
  track.struct_size = sizeof(track);
  assert(rillight_core_get_track(core, 0, &track) == 0);
  assert(track.type == RILLIGHT_CORE_TRACK_AUDIO &&
         track.stream_index == before.audio_stream_index &&
         track.sample_rate == 48000 && track.channels == 1);
  assert(rillight_core_select_subtitle(core, 99, 2) != 0);
  assert(snapshot(core).timeline_version == before.timeline_version &&
         snapshot(core).subtitle_stream_index == -1);
  assert(wait_for(core, [](const auto &state) {
    return state.first_audio_frame_ready != 0 &&
           state.state != RILLIGHT_CORE_FAILED;
  }));
  assert(rillight_core_set_playing(core, 0, 3) == 0);
  assert(snapshot(core).state == RILLIGHT_CORE_PAUSED);
  assert(rillight_core_set_playing(core, 1, 3) != 0);  // Stale command.
  assert(rillight_core_set_speed(core, 2.0, 4) == 0);
  assert(wait_for(core, [](const auto &state) {
    return state.playback_speed == 2.0 && state.first_audio_frame_ready != 0;
  }));
  auto *frame = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16);
  assert(frame && frame->data_size > 0 && frame->sample_rate == 48000);
  bool nonzero = false;
  for (int i = 0; i < frame->data_size; ++i) nonzero |= frame->data[i] != 0;
  assert(nonzero);
  rillight_core_release_frame(frame);
  assert(rillight_core_seek(core, 0, 5) == 0);
  auto after = snapshot(core);
  assert(after.timeline_version > before.timeline_version);
  assert(rillight_core_report_audio_played(
             core, after.session_id, before.timeline_version, 1000, 0) != 0);
  assert(wait_for(core, [](const auto &state) {
    return state.first_audio_frame_ready != 0;
  }));
  assert(rillight_core_report_output_drained(
             core, after.session_id, after.timeline_version) == 0);
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(5);
  int speed_samples = 0;
  while (snapshot(core).state != RILLIGHT_CORE_ENDED &&
         std::chrono::steady_clock::now() < deadline) {
    frame = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16);
    if (frame) {
      speed_samples += frame->sample_count;
      rillight_core_release_frame(frame);
    }
    else std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  assert(snapshot(core).state == RILLIGHT_CORE_ENDED);
  assert(speed_samples > 1500 && speed_samples < 3500);
  assert(rillight_core_configure_hardware(core, RILLIGHT_CORE_HW_VAAPI, 1) == 0);
  assert(rillight_core_open(core, "synthetic.bmp", 6) == 0);
  assert(wait_for(core, [](const auto &state) {
    return state.session_id == 2 && state.first_video_frame_ready != 0;
  }));
  assert(snapshot(core).state == RILLIGHT_CORE_PAUSED);
  assert(rillight_core_track_count(core) == 1);
  track.struct_size = sizeof(track);
  assert(rillight_core_get_track(core, 0, &track) == 0);
  assert(track.type == RILLIGHT_CORE_TRACK_VIDEO &&
         track.width == 32 && track.height == 32 &&
         track.actual_hardware == RILLIGHT_CORE_HW_NONE);
  assert(snapshot(core).preferred_hardware == RILLIGHT_CORE_HW_VAAPI &&
         snapshot(core).allow_software_fallback != 0);
  frame = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
  assert(frame && frame->width == 32 && frame->height == 32 &&
         frame->data_size == 32 * 32 * 4);
  assert(frame->data[0] == 200);
  rillight_core_release_frame(frame);
  assert(rillight_core_open(core, "synthetic.wav", 7) == 0);
  assert(wait_for(core, [](const auto &state) {
    return state.session_id == 3 && state.first_audio_frame_ready != 0;
  }));
  rillight_core_destroy(core);
  core = rillight_core_create(&io);
  assert(core);
  assert(rillight_core_configure_hardware(core, RILLIGHT_CORE_HW_VAAPI, 0) == 0);
  assert(rillight_core_open(core, "synthetic.bmp", 1) == 0);
  assert(wait_for(core, [](const auto &state) {
    return state.state == RILLIGHT_CORE_FAILED && state.ffmpeg_error != 0;
  }));
  assert(snapshot(core).first_video_frame_ready == 0);
  rillight_core_destroy(core);
  Blocking blocking;
  RillightCoreIo blocked_io{&blocking, blocked_open, blocked_read,
                            blocked_seek, blocked_close, blocked_cancel};
  core = rillight_core_create(&blocked_io);
  assert(core);
  assert(rillight_core_open(core, "blocked.stream", 1) == 0);
  const auto close_started = std::chrono::steady_clock::now();
  rillight_core_destroy(core);
  assert(std::chrono::steady_clock::now() - close_started <
         std::chrono::seconds(2));
  return 0;
}
