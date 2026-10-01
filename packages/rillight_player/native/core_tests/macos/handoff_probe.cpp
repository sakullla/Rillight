#include "../../core/rillight_core.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {
struct FileSession { std::string path; };

void* Open(void* opaque, const char* url, int) {
  auto* session = static_cast<FileSession*>(opaque);
  if (!url || session->path != url) return nullptr;
  return std::fopen(url, "rb");
}
int Read(void*, void* handle, uint8_t* bytes, int size) {
  auto* file = static_cast<FILE*>(handle);
  if (!file || !bytes || size <= 0) return -1;
  const size_t count = std::fread(bytes, 1, static_cast<size_t>(size), file);
  if (count > 0) return static_cast<int>(count);
  return std::ferror(file) ? -5 : 0;
}
int64_t Seek(void*, void* handle, int64_t offset, int whence) {
  auto* file = static_cast<FILE*>(handle);
  if (!file) return -1;
  if (whence == 0x10000) {
    const long previous = std::ftell(file);
    if (std::fseek(file, 0, SEEK_END) != 0) return -1;
    const long size = std::ftell(file);
    std::fseek(file, previous, SEEK_SET);
    return size;
  }
  if (std::fseek(file, offset, whence & 0xffff) != 0) return -1;
  return std::ftell(file);
}
void Close(void*, void* handle) { if (handle) std::fclose(static_cast<FILE*>(handle)); }
void Cancel(void*) {}

float HalfToFloat(uint16_t half) {
  const uint32_t sign = static_cast<uint32_t>(half & 0x8000u) << 16;
  const uint32_t exponent = (half >> 10) & 0x1fu;
  const uint32_t mantissa = half & 0x3ffu;
  uint32_t bits = exponent == 0 ? sign :
      exponent == 31 ? sign | 0x7f800000u | (mantissa << 13) :
      sign | ((exponent + 112) << 23) | (mantissa << 13);
  float value = 0;
  std::memcpy(&value, &bits, sizeof(value));
  return value;
}

struct Core {
  FileSession session;
  RillightCore* pointer = nullptr;
  explicit Core(std::string path) : session{std::move(path)} {}
  ~Core() { if (pointer) rillight_core_destroy(pointer); }
  int Open(int edr) {
    RillightCoreIo io{&session, ::Open, Read, Seek, Close, Cancel, Cancel};
    pointer = rillight_core_create(&io);
    if (!pointer) return 2;
    if (rillight_core_configure_hardware(pointer, RILLIGHT_CORE_HW_VIDEOTOOLBOX, 1) != 0)
      return 3;
    if (rillight_core_configure_macos_edr(pointer, edr) != 0) return 3;
    if (rillight_core_open(pointer, session.path.c_str(), 1) != 0) return 4;
    return 0;
  }
  bool Snapshot(RillightCoreSnapshot* snapshot) {
    snapshot->struct_size = sizeof(*snapshot);
    return rillight_core_snapshot(pointer, snapshot) == 0;
  }
  uint32_t Hardware() {
    const int count = rillight_core_track_count(pointer);
    for (int index = 0; index < count; ++index) {
      RillightCoreTrack track{};
      track.struct_size = sizeof(track);
      if (rillight_core_get_track(pointer, index, &track) == 0 &&
          track.type == RILLIGHT_CORE_TRACK_VIDEO && track.actual_hardware != 0)
        return track.actual_hardware;
    }
    return 0;
  }
};

struct Tally {
  int video = 0;
  int audio = 0;
  int half = 0;
  int rgba = 0;
  int other = 0;
  float peak = 0;
  int sample_rate = 0;
  int channels = 0;
  int max_queued_video = 0;
  int max_queued_audio = 0;
  int transfer = -1;
  uint32_t hardware = 0;
  std::vector<int64_t> video_gap_us;
  std::chrono::steady_clock::time_point last_video{};
};

void Absorb(Tally* tally, RillightCoreFrame* frame) {
  if (frame->type == RILLIGHT_CORE_AUDIO_S16) {
    ++tally->audio;
    tally->sample_rate = frame->sample_rate;
    tally->channels = frame->channels;
    return;
  }
  ++tally->video;
  tally->transfer = frame->source_color_transfer;
  const auto now = std::chrono::steady_clock::now();
  if (tally->last_video.time_since_epoch().count() != 0) {
    tally->video_gap_us.push_back(std::chrono::duration_cast<std::chrono::microseconds>(
        now - tally->last_video).count());
  }
  tally->last_video = now;
  if (frame->type == RILLIGHT_CORE_VIDEO_RGBA16F) {
    ++tally->half;
    const int pixels = std::min(frame->width * frame->height, frame->data_size / 8);
    const auto* samples = reinterpret_cast<const uint16_t*>(frame->data);
    for (int pixel = 0; pixel < pixels; pixel += 16) {
      for (int channel = 0; channel < 3; ++channel)
        tally->peak = std::max(tally->peak, HalfToFloat(samples[pixel * 4 + channel]));
    }
  } else if (frame->type == RILLIGHT_CORE_VIDEO_RGBA) {
    ++tally->rgba;
    for (int offset = 0; offset + 3 < frame->data_size; offset += 64)
      tally->peak = std::max(tally->peak, frame->data[offset] / 255.0f);
  } else {
    ++tally->other;
  }
}

int Collect(Core* core, Tally* tally, int want_video, int want_audio,
            std::chrono::milliseconds budget) {
  const auto deadline = std::chrono::steady_clock::now() + budget;
  while (std::chrono::steady_clock::now() < deadline) {
    RillightCoreSnapshot snapshot{};
    if (!core->Snapshot(&snapshot)) return 5;
    if (snapshot.state == RILLIGHT_CORE_FAILED) {
      std::printf(" failed=%d", snapshot.ffmpeg_error);
      return 6;
    }
    tally->max_queued_video = std::max(tally->max_queued_video, snapshot.queued_video_frames);
    tally->max_queued_audio = std::max(tally->max_queued_audio, snapshot.queued_audio_frames);
    tally->hardware = core->Hardware();
    bool progressed = false;
    if (RillightCoreFrame* frame = rillight_core_take_frame(core->pointer, RILLIGHT_CORE_VIDEO_RGBA)) {
      Absorb(tally, frame);
      rillight_core_release_frame(frame);
      progressed = true;
    }
    if (RillightCoreFrame* frame = rillight_core_take_frame(core->pointer, RILLIGHT_CORE_AUDIO_S16)) {
      Absorb(tally, frame);
      rillight_core_release_frame(frame);
      progressed = true;
    }
    if (tally->video >= want_video && tally->audio >= want_audio) return 0;
    if (!progressed) std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return tally->video >= want_video && tally->audio >= want_audio ? 0 : 7;
}

void Print(const char* name, int code, const Tally& tally) {
  std::printf("CASE %s ok=%d video=%d audio=%d half=%d rgba=%d other=%d peak=%.3f transfer=%d rate=%d ch=%d hw=%u qv=%d qa=%d gaps=%zu\n",
              name, code == 0, tally.video, tally.audio, tally.half, tally.rgba, tally.other,
              tally.peak, tally.transfer, tally.sample_rate, tally.channels, tally.hardware,
              tally.max_queued_video, tally.max_queued_audio, tally.video_gap_us.size());
}

int Median(std::vector<int64_t> values) {
  if (values.empty()) return -1;
  std::sort(values.begin(), values.end());
  return static_cast<int>(values[values.size() / 2]);
}

int Lifecycle(const char* path) {
  Core core(path);
  int opened = core.Open(0);
  if (opened != 0) {
    std::printf("CASE lifecycle ok=0 open=%d\n", opened);
    return opened;
  }
  Tally tally;
  int code = Collect(&core, &tally, 8, 4, std::chrono::milliseconds(8000));
  RillightCoreSnapshot before{};
  core.Snapshot(&before);
  const int64_t paused_at = before.position_us;
  if (rillight_core_set_playing(core.pointer, 0, 2) != 0) code = code ? code : 8;
  std::this_thread::sleep_for(std::chrono::milliseconds(250));
  RillightCoreSnapshot held{};
  core.Snapshot(&held);
  const int64_t drift = held.position_us - paused_at;
  if (rillight_core_seek(core.pointer, 1500000, 3) != 0) code = code ? code : 9;
  if (rillight_core_set_playing(core.pointer, 1, 4) != 0) code = code ? code : 10;
  Tally after_seek;
  int seek_code = Collect(&core, &after_seek, 4, 0, std::chrono::milliseconds(8000));
  if (seek_code != 0) code = code ? code : seek_code;
  if (rillight_core_set_speed(core.pointer, 2.0, 5) != 0) code = code ? code : 11;
  Tally after_speed;
  Collect(&core, &after_speed, 4, 0, std::chrono::milliseconds(8000));
  RillightCoreSnapshot sped{};
  core.Snapshot(&sped);
  const bool speed_ok = sped.playback_speed > 1.5;
  const bool pause_ok = drift >= -50000 && drift < 400000;
  const bool queue_ok = tally.max_queued_video <= 8 && tally.max_queued_audio <= 64;
  if (!speed_ok || !pause_ok || !queue_ok) code = code ? code : 12;
  std::printf("CASE lifecycle ok=%d pause_drift_us=%lld speed=%.2f seek_video=%d qv=%d qa=%d hw=%u\n",
              code == 0, static_cast<long long>(drift), sped.playback_speed,
              after_seek.video, tally.max_queued_video, tally.max_queued_audio, tally.hardware);
  return code;
}

int WaitSpeed(Core* core, double speed) {
  for (int attempt = 0; attempt < 200; ++attempt) {
    RillightCoreSnapshot snapshot{};
    if (!core->Snapshot(&snapshot)) return 5;
    if (snapshot.state == RILLIGHT_CORE_FAILED) return 6;
    if (snapshot.state == RILLIGHT_CORE_PLAYING &&
        std::abs(snapshot.playback_speed - speed) < 0.05) return 0;
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
  return 7;
}

int Rates(const char* path) {
  Core core(path);
  const int opened = core.Open(0);
  if (opened != 0) {
    std::printf("CASE rates ok=0 open=%d\n", opened);
    return opened;
  }
  const double speeds[] = {1.0, 1.25, 2.0};
  uint64_t operation = 2;
  int code = 0;
  if (WaitSpeed(&core, 1.0) != 0) {
    std::printf("CASE rates ok=0 startup=1\n");
    return 10;
  }
  for (double speed : speeds) {
    if (std::abs(speed - 1.0) > 0.01 &&
        rillight_core_set_speed(core.pointer, speed, operation++) != 0) {
      std::printf("CASE rate-%.2f ok=0 set=1\n", speed);
      return 11;
    }
    const int waited = WaitSpeed(&core, speed);
    Tally tally;
    const int collected = Collect(&core, &tally, 48, 0, std::chrono::milliseconds(8000));
    RillightCoreSnapshot snapshot{};
    core.Snapshot(&snapshot);
    const int median = Median(tally.video_gap_us);
    int64_t max_gap = 0;
    for (int64_t gap : tally.video_gap_us) max_gap = std::max(max_gap, gap);
    const int budget = static_cast<int>(16667.0 / speed);
    const bool ok = waited == 0 && collected == 0 && median > 0 && median < budget * 2;
    if (!ok) code = code ? code : 12;
    std::printf("CASE rate-%.2f ok=%d waited=%d speed=%.2f video=%d median_gap_us=%d max_gap_us=%lld budget_us=%d qv=%d hw=%u\n",
                speed, ok, waited, snapshot.playback_speed, tally.video, median,
                static_cast<long long>(max_gap), budget, tally.max_queued_video, tally.hardware);
  }
  return code;
}

int Timed(const char* name, const char* path, int edr, int want_video, int want_audio) {
  Core core(path);
  int opened = core.Open(edr);
  if (opened != 0) {
    std::printf("CASE %s ok=0 open=%d\n", name, opened);
    return opened;
  }
  Tally tally;
  int code = Collect(&core, &tally, want_video, want_audio, std::chrono::milliseconds(12000));
  const int median = Median(tally.video_gap_us);
  Print(name, code, tally);
  if (!tally.video_gap_us.empty())
    std::printf("CASE %s median_gap_us=%d\n", name, median);
  return code;
}
}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: handoff_probe <lifecycle|rates|play|hdr> <file> [edr]\n");
    return 1;
  }
  const std::string mode = argv[1];
  if (mode == "lifecycle") return Lifecycle(argv[2]);
  if (mode == "rates") return Rates(argv[2]);
  const int edr = argc > 3 && std::strcmp(argv[3], "1") == 0;
  const int video = mode == "audio" ? 0 : mode == "pace" ? 90 : 4;
  const int audio = mode == "silent" || mode == "pace" ? 0 : 2;
  return Timed(mode.c_str(), argv[2], edr, video, audio);
}
