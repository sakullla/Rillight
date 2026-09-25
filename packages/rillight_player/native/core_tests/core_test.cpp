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
  bool entered = false;
  bool cancelled = false;
};

struct SeekBlockingMedia {
  Bytes wav;
  std::mutex mutex;
  std::condition_variable wake;
  bool entered = false;
  bool cancelled = false;
  bool block_armed = false;
  bool gate_consumed = false;
  int cancel_count = 0;
};

struct EofGateMedia {
  Bytes wav;
  std::mutex mutex;
  std::condition_variable wake;
  bool armed = false;
  int entered_count = 0;
  int released_count = 0;
};

struct OverlapSeekMedia {
  Bytes wav;
  std::mutex mutex;
  std::condition_variable wake;
  bool armed = false;
  bool entered = false;
  bool cancelled = false;
  bool consumed = false;
  int targeted_cancel_count = 0;
};

void append16(std::vector<uint8_t> &data, uint16_t value) {
  data.push_back(static_cast<uint8_t>(value));
  data.push_back(static_cast<uint8_t>(value >> 8));
}

void append32(std::vector<uint8_t> &data, uint32_t value) {
  append16(data, static_cast<uint16_t>(value));
  append16(data, static_cast<uint16_t>(value >> 16));
}

Bytes make_wav(uint32_t samples = 4800) {
  Bytes bytes;
  auto &data = bytes.data;
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
void cancel_media_io(void *) {}

void *blocked_open(void *opaque, const char *, int) { return opaque; }

int blocked_read(void *opaque, void *, uint8_t *, int) {
  auto *blocking = static_cast<Blocking *>(opaque);
  std::unique_lock lock(blocking->mutex);
  blocking->entered = true;
  blocking->wake.notify_all();
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

void *seek_block_open(void *opaque, const char *, int) {
  auto *media = static_cast<SeekBlockingMedia *>(opaque);
  media->wav.offset = 0;
  return &media->wav;
}

int seek_block_read(void *opaque, void *handle, uint8_t *buffer, int size) {
  auto *media = static_cast<SeekBlockingMedia *>(opaque);
  {
    std::unique_lock lock(media->mutex);
    // The test arms only after a decoded frame is ready. The next IO read on
    // that timeline then remains blocked until seek signals cancellation.
    if (media->block_armed && !media->gate_consumed) {
      media->entered = true;
      media->wake.notify_all();
      media->wake.wait(lock, [&] { return media->cancelled; });
      media->gate_consumed = true;
      return -5;  // The core discards the cancelled old-timeline read.
    }
  }
  return read(nullptr, handle, buffer, std::min(size, 4096));
}

void seek_block_cancel(void *opaque) {
  auto *media = static_cast<SeekBlockingMedia *>(opaque);
  {
    std::lock_guard lock(media->mutex);
    media->cancelled = true;
    ++media->cancel_count;
  }
  media->wake.notify_all();
}

void *eof_gate_open(void *opaque, const char *, int) {
  auto *media = static_cast<EofGateMedia *>(opaque);
  media->wav.offset = 0;
  return &media->wav;
}

int eof_gate_read(void *opaque, void *handle, uint8_t *buffer, int size) {
  auto *media = static_cast<EofGateMedia *>(opaque);
  auto *bytes = static_cast<Bytes *>(handle);
  if (bytes->offset == bytes->data.size()) {
    std::unique_lock lock(media->mutex);
    media->wake.wait(lock, [&] { return media->armed; });
    if (media->entered_count >= 2) return 0;
    const int gate = ++media->entered_count;
    media->wake.notify_all();
    media->wake.wait(lock, [&] { return media->released_count >= gate; });
    return 0;
  }
  return read(nullptr, handle, buffer, std::min(size, 4096));
}

void eof_gate_release(void *opaque) {
  auto *media = static_cast<EofGateMedia *>(opaque);
  {
    std::lock_guard lock(media->mutex);
    media->armed = true;
    media->released_count = media->entered_count;
  }
  media->wake.notify_all();
}

void *overlap_open(void *opaque, const char *, int) {
  auto *media = static_cast<OverlapSeekMedia *>(opaque);
  media->wav.offset = 0;
  return &media->wav;
}

int64_t overlap_seek(void *opaque, void *handle, int64_t offset, int whence) {
  auto *media = static_cast<OverlapSeekMedia *>(opaque);
  if (whence != 0x10000) {
    std::unique_lock lock(media->mutex);
    if (media->armed && !media->consumed) {
      const int prior_cancels = media->targeted_cancel_count;
      media->entered = true;
      media->wake.notify_all();
      media->wake.wait(lock, [&] {
        return media->cancelled ||
               media->targeted_cancel_count > prior_cancels;
      });
      media->consumed = true;
      return -5;  // Old seek fails after the newer timeline cancels it.
    }
  }
  return seek(nullptr, handle, offset, whence);
}

void overlap_cancel(void *opaque) {
  auto *media = static_cast<OverlapSeekMedia *>(opaque);
  {
    std::lock_guard lock(media->mutex);
    media->cancelled = true;
  }
  media->wake.notify_all();
}

void overlap_cancel_media_io(void *opaque) {
  auto *media = static_cast<OverlapSeekMedia *>(opaque);
  {
    std::lock_guard lock(media->mutex);
    ++media->targeted_cancel_count;
  }
  media->wake.notify_all();
}

RillightCoreSnapshot snapshot(RillightCore *core) {
  RillightCoreSnapshot value{};
  value.struct_size = sizeof(value);
  assert(rillight_core_snapshot(core, &value) == 0);
  return value;
}

template <typename Predicate>
bool wait_for(RillightCore *core, Predicate predicate,
              bool drain_audio = false) {
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(5);
  while (std::chrono::steady_clock::now() < deadline) {
    if (predicate(snapshot(core))) return true;
    if (drain_audio) {
      auto *frame = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16);
      rillight_core_release_frame(frame);
    }
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
  RillightCoreIo io{&media, open, read, seek, close, nullptr,
                    cancel_media_io};
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
  // The short WAV may already have reached real EOF here. The gated EOF
  // fixture below checks premature drain without depending on this race.
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(5);
  int speed_samples = 0;
  bool output_reported = false;
  while (snapshot(core).state != RILLIGHT_CORE_ENDED &&
         std::chrono::steady_clock::now() < deadline) {
    frame = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16);
    if (frame) {
      speed_samples += frame->sample_count;
      rillight_core_release_frame(frame);
    }
    else std::this_thread::sleep_for(std::chrono::milliseconds(5));
    if (!output_reported && snapshot(core).source_eof) {
      assert(rillight_core_report_output_drained(
                 core, after.session_id, after.timeline_version) == 0);
      output_reported = true;
    }
  }
  assert(output_reported);
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
                            blocked_seek, blocked_close, blocked_cancel,
                            blocked_cancel};
  core = rillight_core_create(&blocked_io);
  assert(core);
  assert(rillight_core_open(core, "blocked.stream", 1) == 0);
  {
    std::unique_lock lock(blocking.mutex);
    assert(blocking.wake.wait_for(lock, std::chrono::seconds(2), [&] {
      return blocking.entered;
    }));
  }
  const auto opening = snapshot(core);
  assert(opening.state == RILLIGHT_CORE_OPENING);
  assert(rillight_core_set_speed(core, 1.5, 2) != 0);
  assert(rillight_core_select_audio(core, 0, 2) != 0);
  assert(rillight_core_select_subtitle(core, -1, 2) != 0);
  assert(snapshot(core).timeline_version == opening.timeline_version &&
         snapshot(core).operation_id == opening.operation_id &&
         snapshot(core).state == RILLIGHT_CORE_OPENING);
  const auto close_started = std::chrono::steady_clock::now();
  rillight_core_destroy(core);
  assert(std::chrono::steady_clock::now() - close_started <
         std::chrono::seconds(2));

  SeekBlockingMedia seek_media;
  seek_media.wav = make_wav(48000 * 30);
  RillightCoreIo seek_block_io{&seek_media, seek_block_open, seek_block_read,
                               seek, [](void *, void *) {}, seek_block_cancel,
                               seek_block_cancel};
  core = rillight_core_create(&seek_block_io);
  assert(core && rillight_core_open(core, "seek-blocked.wav", 1) == 0);
  assert(wait_for(core, [](const auto &state) {
    return state.first_audio_frame_ready && state.state != RILLIGHT_CORE_FAILED;
  }));
  {
    std::lock_guard lock(seek_media.mutex);
    seek_media.block_armed = true;
  }
  seek_media.wake.notify_all();
  const auto entered_deadline = std::chrono::steady_clock::now() +
                                std::chrono::seconds(5);
  bool entered = false;
  while (std::chrono::steady_clock::now() < entered_deadline && !entered) {
    {
      std::lock_guard lock(seek_media.mutex);
      entered = seek_media.entered;
    }
    if (entered) break;
    auto *queued = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16);
    const bool had_frame = queued != nullptr;
    rillight_core_release_frame(queued);
    if (!had_frame) std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  assert(entered);
  const auto blocked_timeline = snapshot(core).timeline_version;
  const auto seek_started = std::chrono::steady_clock::now();
  assert(rillight_core_seek(core, 0, 2) == 0);
  assert(std::chrono::steady_clock::now() - seek_started <
         std::chrono::milliseconds(500));
  assert(wait_for(core, [blocked_timeline](const auto &state) {
    return state.timeline_version > blocked_timeline &&
           state.first_audio_frame_ready && state.state != RILLIGHT_CORE_FAILED;
  }));
  assert(seek_media.cancel_count == 1);
  frame = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16);
  assert(frame && frame->timeline_version > blocked_timeline);
  rillight_core_release_frame(frame);
  const auto first_recovery = snapshot(core).timeline_version;
  assert(rillight_core_seek(core, 0, 3) == 0);
  assert(wait_for(core, [first_recovery](const auto &state) {
    return state.timeline_version > first_recovery &&
           state.first_audio_frame_ready && state.state != RILLIGHT_CORE_FAILED;
  }));
  frame = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16);
  assert(frame && frame->timeline_version > first_recovery);
  rillight_core_release_frame(frame);
  rillight_core_destroy(core);

  OverlapSeekMedia overlap_media;
  overlap_media.wav = make_wav(48000 * 30);
  RillightCoreIo overlap_io{&overlap_media, overlap_open, read,
                            overlap_seek, [](void *, void *) {},
                            overlap_cancel, overlap_cancel_media_io};
  core = rillight_core_create(&overlap_io);
  assert(core && rillight_core_open(core, "overlap.wav", 1) == 0);
  assert(wait_for(core, [](const auto &state) {
    return state.first_audio_frame_ready && state.state != RILLIGHT_CORE_FAILED;
  }));
  {
    std::lock_guard lock(overlap_media.mutex);
    overlap_media.armed = true;
  }
  assert(rillight_core_seek(core, 500000, 2) == 0);
  {
    std::unique_lock lock(overlap_media.mutex);
    assert(overlap_media.wake.wait_for(lock, std::chrono::seconds(5), [&] {
      return overlap_media.entered;
    }));
  }
  int cancels_before_second_seek;
  {
    std::lock_guard lock(overlap_media.mutex);
    cancels_before_second_seek = overlap_media.targeted_cancel_count;
  }
  const auto first_seek_timeline = snapshot(core).timeline_version;
  assert(rillight_core_seek(core, 0, 3) == 0);
  assert(wait_for(core, [first_seek_timeline](const auto &state) {
    return state.timeline_version > first_seek_timeline &&
           state.first_audio_frame_ready && state.state != RILLIGHT_CORE_FAILED;
  }));
  assert(snapshot(core).ffmpeg_error == 0);
  {
    std::lock_guard lock(overlap_media.mutex);
    assert(overlap_media.targeted_cancel_count > cancels_before_second_seek);
  }
  rillight_core_destroy(core);

  EofGateMedia eof_media;
  eof_media.wav = make_wav(48000 * 30);
  RillightCoreIo eof_io{&eof_media, eof_gate_open, eof_gate_read,
                        seek, [](void *, void *) {}, eof_gate_release,
                        eof_gate_release};
  core = rillight_core_create(&eof_io);
  assert(core && rillight_core_open(core, "eof-gated.wav", 1) == 0);
  assert(wait_for(core, [](const auto &state) {
    return state.first_audio_frame_ready && state.state != RILLIGHT_CORE_FAILED;
  }));
  {
    std::lock_guard lock(eof_media.mutex);
    eof_media.armed = true;
  }
  eof_media.wake.notify_all();
  const auto wait_eof_gate = [&](int target) {
    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::seconds(5);
    while (std::chrono::steady_clock::now() < deadline) {
      {
        std::lock_guard lock(eof_media.mutex);
        if (eof_media.entered_count >= target) return true;
      }
      auto *queued = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16);
      const bool had_frame = queued != nullptr;
      rillight_core_release_frame(queued);
      if (!had_frame) std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    return false;
  };
  assert(wait_eof_gate(1));
  const auto old_eof = snapshot(core);
  assert(!old_eof.source_eof);
  assert(rillight_core_seek(core, 0, 2) == 0);
  const auto new_timeline = snapshot(core).timeline_version;
  assert(new_timeline > old_eof.timeline_version);
  assert(rillight_core_report_output_drained(
             core, old_eof.session_id, old_eof.timeline_version) != 0);
  assert(wait_eof_gate(2));
  assert(snapshot(core).timeline_version == new_timeline);
  assert(!snapshot(core).source_eof);
  assert(rillight_core_report_output_drained(
             core, old_eof.session_id, new_timeline) != 0);
  eof_gate_release(&eof_media);
  assert(wait_for(core, [new_timeline](const auto &state) {
    return state.timeline_version == new_timeline && state.source_eof &&
           state.first_audio_frame_ready && state.state != RILLIGHT_CORE_FAILED;
  }, true));
  while ((frame = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16)))
    rillight_core_release_frame(frame);
  assert(rillight_core_report_output_drained(
             core, old_eof.session_id, new_timeline) == 0);
  assert(wait_for(core, [](const auto &state) {
    return state.state == RILLIGHT_CORE_ENDED;
  }));
  rillight_core_destroy(core);
  return 0;
}
