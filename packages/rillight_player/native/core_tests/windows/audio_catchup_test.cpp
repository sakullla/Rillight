#include "../../../windows/audio_output.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <thread>

namespace {
using Clock = std::chrono::steady_clock;

// Reproduce decoded TrueHD's 40-sample blocks with audio starting 500 ms
// behind the clock. Use the production output loop and a real WASAPI endpoint.
struct Source {
  Clock::time_point started = Clock::now();
  int next = 0;
  std::atomic<int> taken{0};
  std::atomic<int> released{0};
  std::atomic<int> reports{0};
  std::atomic<int64_t> played{0};
  std::atomic<bool> unavailable{false};
  int64_t Position() const {
    return 500000 + std::chrono::duration_cast<std::chrono::microseconds>(
                        Clock::now() - started).count();
  }
};

struct Block {
  RillightCoreFrame frame{};
  int16_t samples[80]{};  // Silence: this verifies consumption, not sound.
  Source* owner;
};

Source& Get(RillightCore* core) {
  return *reinterpret_cast<Source*>(core);
}

int Snapshot(RillightCore* core, RillightCoreSnapshot* state) {
  *state = {};
  state->struct_size = sizeof(*state);
  state->state = RILLIGHT_CORE_PLAYING;
  state->session_id = 1;
  state->timeline_version = 1;
  state->position_us = Get(core).Position();
  state->playback_speed = 1.0;
  state->queued_audio_frames = 16;
  return 0;
}

RillightCoreFrame* Take(RillightCore* core, int type) {
  if (type != RILLIGHT_CORE_AUDIO_S16) return nullptr;
  auto& source = Get(core);
  const int64_t pts = static_cast<int64_t>(source.next) * 40 * 1000000 / 48000;
  if (pts > source.Position() + 250000) return nullptr;
  auto* block = new Block;
  block->owner = &source;
  auto& frame = block->frame;
  frame.struct_size = sizeof(frame);
  frame.type = RILLIGHT_CORE_AUDIO_S16;
  frame.session_id = 1;
  frame.timeline_version = 1;
  frame.pts_us = pts;
  frame.sample_rate = 48000;
  frame.channels = 2;
  frame.sample_count = 40;
  frame.data = reinterpret_cast<uint8_t*>(block->samples);
  frame.data_size = sizeof(block->samples);
  ++source.next;
  ++source.taken;
  return &frame;
}

void Release(RillightCoreFrame* frame) {
  auto* block = reinterpret_cast<Block*>(frame);
  ++block->owner->released;
  delete block;
}

int Played(RillightCore* core, uint64_t, uint64_t, int64_t end,
           int64_t delay) {
  auto& source = Get(core);
  source.played = end - delay;
  ++source.reports;
  return 0;
}

int Unavailable(RillightCore* core, uint64_t, uint64_t) {
  Get(core).unavailable = true;
  return 0;
}
}  // namespace

int main() {
  try {
    // Flutter has already loaded system GPU dependencies before CoreApi runs.
    // Seed the standalone harness with the same SDK DLL and system imports.
    wchar_t executable[MAX_PATH]{};
    if (!GetModuleFileNameW(nullptr, executable, MAX_PATH)) return 1;
    const auto core_path = std::filesystem::path(executable).parent_path() /
                           L"librillight_core.dll";
    struct Library {
      HMODULE handle;
      ~Library() { if (handle) FreeLibrary(handle); }
    } library{LoadLibraryExW(core_path.c_str(), nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS)};
    if (!library.handle) {
      std::fprintf(stderr, "SDK load error=%lu\n", GetLastError());
      return 1;
    }
    auto api = std::make_shared<CoreApi>();
    api->snapshot = Snapshot;
    api->take_frame = Take;
    api->release_frame = Release;
    api->configure_audio_sink = [](RillightCore*, const RillightCoreAudioSink*) {
      return 0;
    };
    api->report_audio_played = Played;
    api->report_audio_unavailable = Unavailable;
    Source source;
    AudioOutput output(reinterpret_cast<RillightCore*>(&source), api);
    output.Start();
    const auto deadline = Clock::now() + std::chrono::seconds(2);
    while (source.reports == 0 && output.error().empty() &&
           Clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    const int first_reports = source.reports;
    const int64_t first_position = source.played;
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    output.Stop();
    const bool passed = first_reports > 0 &&
        source.reports > first_reports &&
        source.played > first_position + 100000 &&
        source.released >= 600 && source.taken == source.released &&
        !source.unavailable && output.error().empty();
    std::printf("tiny PCM catch-up: reports=%d released=%d advance_us=%lld "
                "balanced=%d error=%s\n", source.reports.load(),
                source.released.load(),
                static_cast<long long>(source.played - first_position),
                source.taken == source.released, output.error().c_str());
    return passed ? 0 : 1;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
