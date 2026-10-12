#include "core_state.h"
#include "core_video.h"

namespace rillight::core {
int64_t playback_position(const RillightCoreImpl *core,
                          Clock::time_point now) {
  if (core->state != RILLIGHT_CORE_PLAYING) return core->base_position;
  const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
      now - core->base_time).count();
  const int64_t position = core->base_position + static_cast<int64_t>(
      std::max<int64_t>(0, elapsed) * core->speed);
  return core->audio_clock_active
      ? std::min(position, std::max(core->base_position, core->audio_clock_limit))
      : position;
}

RillightCoreImpl *impl(RillightCore *core) {
  return reinterpret_cast<RillightCoreImpl *>(core);
}

void clear_queue(std::deque<RillightCoreFrame *> &queue, size_t &bytes) {
  while (!queue.empty()) {
    auto *frame = queue.front();
    queue.pop_front();
    rillight_core_release_frame(frame);
  }
  bytes = 0;
}

void drop_passthrough_frames(RillightCoreImpl *core) {
  std::deque<RillightCoreFrame *> kept;
  size_t bytes = 0;
  while (!core->audio.empty()) {
    auto *frame = core->audio.front();
    core->audio.pop_front();
    if (frame->type == RILLIGHT_CORE_AUDIO_PASSTHROUGH) {
      rillight_core_release_frame(frame);
      continue;
    }
    kept.push_back(frame);
    bytes += static_cast<size_t>(std::max(frame->data_size, 0));
  }
  core->audio.swap(kept);
  core->audio_bytes = bytes;
}

bool unity_speed(double speed) { return speed > 0.999 && speed < 1.001; }

bool passthrough_still_wanted(const RillightCoreImpl *core,
                              const RillightCoreFrame *frame) {
  if (!unity_speed(core->speed)) return false;
  return (rillight_audio_accept_for_gain(core->sink_accept, core->volume) &
          rillight_passthrough_accept_bit(frame->audio_codec_id)) != 0;
}

void reset_frames(RillightCoreImpl *core) {
  core->video_processing = {};
  core->presentation_floor_us = 0;
  rillight_core_release_frame(core->displayed_clean);
  core->displayed_clean = nullptr;
  core->subtitle_redraw = false;
  rillight_core_release_frame(core->subtitle_preview);
  core->subtitle_preview = nullptr;
  clear_queue(core->video, core->video_bytes);
  clear_queue(core->audio, core->audio_bytes);
  core->first_video = false;
  core->first_audio = false;
  core->eof = false;
  core->input_exhausted = false;
  core->output_drained = false;
  core->audio_clock_active = false;
  core->audio_clock_limit = 0;
  core->audio_clock_handed_off = false;
  core->paused_video_frame_emitted = false;
  core->io_fatal_error = 0;
}

bool accept_operation(RillightCoreImpl *core, uint64_t operation) {
  if (!operation || operation <= core->operation ||
      core->state == RILLIGHT_CORE_CLOSING) {
    return false;
  }
  core->operation = operation;
  return true;
}

void update_decode_diagnostics(RillightCoreImpl *core, Decoder &decoder,
                               const AVFrame *frame) {
  const auto *description = av_pix_fmt_desc_get(
      static_cast<AVPixelFormat>(frame->format));
  // MediaCodec byte output uses CPU pixel formats but carries the actual
  // decoder component name. Other hwaccel paths expose hardware formats.
  const bool hardware_frame =
      (description && (description->flags & AV_PIX_FMT_FLAG_HWACCEL)) ||
      (decoder.hardware == RILLIGHT_CORE_HW_MEDIACODEC &&
       av_dict_get(frame->metadata, "rillight.mediacodec.name", nullptr, 0));
  const int active = hardware_frame ? static_cast<int>(decoder.hardware)
                                    : RILLIGHT_CORE_HW_NONE;
  if (decoder.decoded_hardware == active) return;
  decoder.decoded_hardware = active;
  if (decoder.hardware != RILLIGHT_CORE_HW_NONE) {
    decoder.diagnostics = active != RILLIGHT_CORE_HW_NONE
        ? decoder.hardware_diagnostics
        : "software threads=" + std::to_string(decoder.context->thread_count) +
          "; hardware format unavailable (" + decoder.hardware_diagnostics + ")";
  }
  std::lock_guard lock(core->mutex);
  core->decode_diagnostics = decoder.diagnostics;
  for (auto &track : core->tracks) {
    if (track.stream_index == decoder.stream) track.actual_hardware = active;
  }
}

int enqueue(RillightCoreImpl *core, RillightCoreFrame *frame,
             int video_index, uint64_t timeline) {
  if (!frame) return 0;
  std::unique_lock lock(core->mutex);
  rebase_absolute_program_pts(core, frame);
  const bool audio = rillight_core_frame_is_audio(frame->type);
  auto &queue = audio ? core->audio : core->video;
  auto &bytes = audio ? core->audio_bytes : core->video_bytes;
  // Video and audio decode independently. The first resumed picture can make
  // the timeline PLAYING while its audio lane is still decoding preroll.
  // Keep the seek floor fixed for the timeline, independent of readiness and
  // the advancing playback clock, including PCM and compressed passthrough.
  if (frame->pts_us != -1 && frame->pts_us + (audio ? 20000 : 5000) <
          core->presentation_floor_us) {
    lock.unlock();
    rillight_core_release_frame(frame);
    return 0;
  }
  const auto max_count = audio ? kMaxAudioFrames : kMaxVideoFrames;
  const auto max_bytes = audio
                             ? kMaxAudioBytes
                             : kMaxVideoBytes * ((core->hdr_video || core->macos_edr) ? 2 : 1);
  core->wake.wait(lock, [&] {
    return core->stop || core->decode_abort || core->timeline != timeline ||
           (queue.size() < max_count && bytes + frame->data_size <= max_bytes);
  });
  if (core->stop || core->decode_abort || core->timeline != timeline) {
    lock.unlock();
    rillight_core_release_frame(frame);
    return 0;
  }
  // The packet was classified before this wait. Speed or the sink may have
  // changed; the caller decodes PCM instead of leaving a compressed frame.
  if (audio && frame->type == RILLIGHT_CORE_AUDIO_PASSTHROUGH &&
      !passthrough_still_wanted(core, frame)) {
    lock.unlock();
    rillight_core_release_frame(frame);
    return AVERROR(EAGAIN);
  }
  if (audio && frame->type == RILLIGHT_CORE_AUDIO_S16 &&
      frame->channels > core->sink_max_channels) {
    lock.unlock();
    rillight_core_release_frame(frame);
    return 0;
  }
  bytes += frame->data_size;
  queue.push_back(frame);
  if (!audio) core->first_video = true;
  if (audio) {
    core->first_audio = true;
    core->audio_delivery = frame->audio_delivery;
    core->audio_channels = frame->channels;
    core->audio_layout = frame->channel_layout;
    core->audio_atmos = frame->audio_delivery == RILLIGHT_CORE_AUDIO_DELIVERY_PASSTHROUGH
                            ? frame->audio_atmos : 0;
    core->audio_codec_id = frame->audio_codec_id;
  } else {
    const auto *video_frame = static_cast<const VideoOutputFrame *>(frame);
    core->dovi_reconstruction = video_frame->dovi_reconstruction;
    core->video_output_kind = dovi_present_output_kind(
        frame->type, core->hdr_video ? 1 : 0, core->macos_edr ? 1 : 0,
        core->android_native_dolby ? 1 : 0);
  }
  if ((video_index >= 0 && core->first_video) ||
      ((video_index < 0 || core->tunnel) && core->first_audio)) {
    if (core->state == RILLIGHT_CORE_OPENING ||
        core->state == RILLIGHT_CORE_BUFFERING ||
        core->state == RILLIGHT_CORE_RECOVERING) {
      // A small lead-in keeps A/V aligned. An absolute TS/HLS PTS larger than
      // the program is not the playback clock; adopting it jumps the seek bar
      // to the end.
      if (core->base_position == 0 && frame->pts_us > 0 &&
          (core->duration <= 0 || frame->pts_us <= core->duration))
        core->base_position = frame->pts_us;
      core->base_time = Clock::now();
      core->state = core->play_intent ? RILLIGHT_CORE_PLAYING
                                      : RILLIGHT_CORE_PAUSED;
    }
  }
  core->wake.notify_all();
  return 0;
}
}  // namespace rillight::core
