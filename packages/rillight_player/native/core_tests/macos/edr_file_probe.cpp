#include "../../core/rillight_core.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {
struct FileSession {
  std::string path;
};

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

void Close(void*, void* handle) {
  if (handle) std::fclose(static_cast<FILE*>(handle));
}

void Cancel(void*) {}

float HalfToFloat(uint16_t half) {
  const uint32_t sign = static_cast<uint32_t>(half & 0x8000u) << 16;
  const uint32_t exponent = (half >> 10) & 0x1fu;
  const uint32_t mantissa = half & 0x3ffu;
  uint32_t bits = 0;
  if (exponent == 0) bits = sign;
  else if (exponent == 31) bits = sign | 0x7f800000u | (mantissa << 13);
  else bits = sign | ((exponent + 112) << 23) | (mantissa << 13);
  float value = 0;
  std::memcpy(&value, &bits, sizeof(value));
  return value;
}

int Run(const char* path, int edr) {
  FileSession session{path};
  RillightCoreIo io{&session, Open, Read, Seek, Close, Cancel, Cancel};
  RillightCore* core = rillight_core_create(&io);
  if (!core) return 2;
  if (rillight_core_configure_hardware(
          core, RILLIGHT_CORE_HW_VIDEOTOOLBOX, 1) != 0 ||
      rillight_core_configure_macos_edr(core, edr) != 0 ||
      rillight_core_open(core, path, 1) != 0) {
    std::fprintf(stderr, "open failed edr=%d\n", edr);
    rillight_core_destroy(core);
    return 3;
  }
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
  int frames = 0;
  int half_frames = 0;
  int rgba_frames = 0;
  float peak = 0;
  uint32_t hardware = 0;
  while (std::chrono::steady_clock::now() < deadline && frames < 8) {
    RillightCoreSnapshot snapshot{};
    snapshot.struct_size = sizeof(snapshot);
    if (rillight_core_snapshot(core, &snapshot) != 0) break;
    if (snapshot.state == RILLIGHT_CORE_FAILED) {
      std::fprintf(stderr, "core failed %d\n", snapshot.ffmpeg_error);
      break;
    }
    const int tracks = rillight_core_track_count(core);
    for (int index = 0; index < tracks; ++index) {
      RillightCoreTrack track{};
      track.struct_size = sizeof(track);
      if (rillight_core_get_track(core, index, &track) == 0 &&
          track.type == RILLIGHT_CORE_TRACK_VIDEO)
        hardware = track.actual_hardware;
    }
    RillightCoreFrame* frame = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
    if (!frame) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
      continue;
    }
    ++frames;
    if (frame->type == RILLIGHT_CORE_VIDEO_RGBA16F) {
      ++half_frames;
      const int pixels = frame->width * frame->height;
      const auto* samples = reinterpret_cast<const uint16_t*>(frame->data);
      for (int pixel = 0; pixel < pixels; ++pixel) {
        for (int channel = 0; channel < 3; ++channel)
          peak = std::max(peak, HalfToFloat(samples[pixel * 4 + channel]));
      }
    } else if (frame->type == RILLIGHT_CORE_VIDEO_RGBA) {
      ++rgba_frames;
      for (int offset = 0; offset < frame->data_size; offset += 4)
        peak = std::max(peak, frame->data[offset] / 255.0f);
    }
    std::printf("frame type=%d %dx%d stride=%d peak=%.3f transfer=%d hardware=%u\n",
                frame->type, frame->width, frame->height, frame->stride, peak,
                frame->source_color_transfer, hardware);
    rillight_core_release_frame(frame);
  }
  std::printf("summary edr=%d frames=%d half=%d rgba=%d peak=%.3f hardware=%u\n",
              edr, frames, half_frames, rgba_frames, peak, hardware);
  rillight_core_destroy(core);
  if (frames == 0) return 4;
  if (edr && (half_frames == 0 || peak <= 1.0f)) return 5;
  if (!edr && (rgba_frames == 0 || half_frames != 0)) return 6;
  return 0;
}
}  // namespace

int main(int argc, char** argv) {
  if (argc != 3) {
    std::fprintf(stderr, "usage: edr_file_probe <file> <0|1>\n");
    return 1;
  }
  return Run(argv[1], std::strcmp(argv[2], "1") == 0);
}
