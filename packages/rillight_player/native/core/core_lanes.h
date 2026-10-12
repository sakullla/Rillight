#pragma once
#include "core_internal.h"

namespace rillight::core {
// The session mutex protects queue/control state; codec and conversion work
// runs outside it. Quiesce retires in-flight work before timeline mutation.
class DecodeLane {
 public:
  using Decode = std::function<int(const AVPacket *, uint64_t)>;
  DecodeLane(RillightCoreImpl *core, size_t budget, int type)
      : core_(core), budget_(budget), type_(type) {}
  ~DecodeLane() { Stop(); }
  bool Start(Decode decode) {
    decode_ = std::move(decode);
    try { thread_ = std::thread([this] { Run(); }); }
    catch (...) { return false; }
    return true;
  }
  int Push(const AVPacket *packet, uint64_t timeline) {
    size_t cost = sizeof(AVPacket);
    if (packet) {
      cost += std::max(0, packet->size);
      for (int i = 0; i < packet->side_data_elems; ++i)
        cost += packet->side_data[i].size;
    }
    if (cost > budget_) return AVERROR(ENOBUFS);
    std::unique_lock lock(core_->mutex);
    const auto video_has_work = [&] {
      return core_->video_packets_pending > 0 || core_->video_decode_busy;
    };
    if (type_ == RILLIGHT_CORE_AUDIO_S16 && core_->video_index >= 0 &&
        !core_->first_video && (bytes_ + cost > budget_ || queue_.size() >= 2048)) {
      // PCM is withheld until the first picture. If video is already queued
      // or decoding, let it finish even on cold open: the demux thread can fill
      // this queue before the video lane gets CPU time. With no video work,
      // cold open fails boundedly; seek recovery skips excess preroll instead
      // of waiting for audio space that cannot become available yet.
      if (!packet) return AVERROR(ENOBUFS);
      if (video_has_work()) {
        core_->wake.wait(lock, [&] {
          return stopped_ || core_->stop || core_->decode_abort ||
              core_->timeline != timeline || core_->first_video ||
              !video_has_work() ||
              (enabled_ && bytes_ + cost <= budget_ && queue_.size() < 2048);
        });
      }
      if (stopped_ || core_->stop || core_->decode_abort ||
          core_->timeline != timeline) return 0;
      if (!core_->first_video && !video_has_work() &&
          (bytes_ + cost > budget_ || queue_.size() >= 2048)) {
        return core_->state == RILLIGHT_CORE_RECOVERING ? 0 : AVERROR(ENOBUFS);
      }
    }
    core_->wake.wait(lock, [&] {
      return stopped_ || core_->stop || core_->decode_abort ||
          core_->timeline != timeline ||
          (enabled_ && bytes_ + cost <= budget_ && queue_.size() < 2048);
    });
    if (stopped_ || core_->stop || core_->decode_abort ||
        core_->timeline != timeline) return 0;
    auto *copy = packet ? av_packet_clone(packet) : nullptr;
    if (packet && !copy) return AVERROR(ENOMEM);
    if (type_ == RILLIGHT_CORE_VIDEO_RGBA && packet)
      core_->video_packets_pending++;
    queue_.push_back({copy, timeline, cost});
    bytes_ += cost;
    core_->wake.notify_all();
    return 0;
  }
  void Quiesce() {
    std::unique_lock lock(core_->mutex);
    enabled_ = false;
    Clear();
    core_->wake.notify_all();
    core_->wake.wait(lock, [&] { return !busy_; });
  }
  void Resume() {
    std::lock_guard lock(core_->mutex);
    enabled_ = true;
    core_->wake.notify_all();
  }
  void Drain(uint64_t timeline) {
    std::unique_lock lock(core_->mutex);
    core_->wake.wait(lock, [&] {
      return core_->stop || core_->decode_abort || core_->timeline != timeline ||
          (queue_.empty() && !busy_);
    });
  }
  void Stop() {
    {
      std::lock_guard lock(core_->mutex);
      stopped_ = true;
      Clear();
      core_->wake.notify_all();
    }
    if (thread_.joinable()) thread_.join();
  }
 private:
  struct Packet { AVPacket *value; uint64_t timeline; size_t cost; };
  void Clear() {
    for (auto &packet : queue_) av_packet_free(&packet.value);
    queue_.clear();
    bytes_ = 0;
    if (type_ == RILLIGHT_CORE_VIDEO_RGBA) core_->video_packets_pending = 0;
  }
  void Run() {
    for (;;) {
      Packet packet{};
      {
        std::unique_lock lock(core_->mutex);
        core_->wake.wait(lock, [&] {
          const bool preview_needed = type_ == RILLIGHT_CORE_VIDEO_RGBA
              ? !core_->first_video : type_ == RILLIGHT_CORE_AUDIO_S16
              ? !core_->first_audio : !core_->first_video;
          return stopped_ || core_->stop || core_->decode_abort ||
              (enabled_ && !queue_.empty() &&
               (queue_.front().timeline != core_->timeline ||
                core_->play_intent || preview_needed));
        });
        if (stopped_ || core_->stop || core_->decode_abort) break;
        packet = queue_.front();
        queue_.pop_front();
        bytes_ -= packet.cost;
        if (type_ == RILLIGHT_CORE_VIDEO_RGBA && packet.value &&
            core_->video_packets_pending > 0)
          core_->video_packets_pending--;
        core_->wake.notify_all();
        if (packet.timeline != core_->timeline) {
          av_packet_free(&packet.value);
          continue;
        }
        busy_ = true;
        if (type_ == RILLIGHT_CORE_VIDEO_RGBA) core_->video_decode_busy = true;
      }
      int result;
      try { result = decode_(packet.value, packet.timeline); }
      catch (...) { result = AVERROR_UNKNOWN; }
      av_packet_free(&packet.value);
      bool failed = false;
      {
        std::lock_guard lock(core_->mutex);
        busy_ = false;
        if (type_ == RILLIGHT_CORE_VIDEO_RGBA) core_->video_decode_busy = false;
        if (result < 0 && packet.timeline == core_->timeline && !core_->stop) {
          int expected = 0;
          core_->decode_error.compare_exchange_strong(expected, result);
          core_->decode_abort = true;
          failed = true;
        }
        core_->wake.notify_all();
      }
      if (failed) {
        core_->io.cancel_media_io(core_->io.opaque);
        break;
      }
    }
  }
  RillightCoreImpl *core_;
  const size_t budget_;
  const int type_;
  Decode decode_;
  std::thread thread_;
  std::deque<Packet> queue_;
  size_t bytes_ = 0;
  bool enabled_ = true, busy_ = false, stopped_ = false;
};

// Hardware receive submits work asynchronously. Keep a bounded decoded-frame
// lane so GPU download / colorspace conversion cannot stop the decoder from
// feeding the next pictures. Audio, subtitles and demux retain their own lanes.
class VideoConvertLane {
 public:
  using Convert = std::function<int(AVFrame *, int, uint32_t, uint64_t)>;
  explicit VideoConvertLane(RillightCoreImpl *core) : core_(core) {}
  ~VideoConvertLane() { Stop(); }
  bool Start(Convert convert) {
    convert_ = std::move(convert);
    try { thread_ = std::thread([this] { Run(); }); }
    catch (...) { return false; }
    return true;
  }
  int Push(AVFrame *frame, int stream, uint32_t hardware, uint64_t timeline) {
    // An opaque MediaCodec output is a retained decoder buffer, not a CPU
    // image. av_image_get_buffer_size rejects it and used to trigger software
    // fallback immediately after the first successful Surface frame.
    const int cost = video_frame_cost(frame);
    if (cost <= 0 || static_cast<size_t>(cost) > kMaxVideoBytes) return AVERROR(ENOBUFS);
    std::unique_lock lock(core_->mutex);
    core_->wake.wait(lock, [&] {
      return stopped_ || core_->stop || core_->decode_abort ||
          core_->timeline != timeline ||
          (enabled_ && queue_.size() < 3 && bytes_ + cost <= kMaxVideoBytes);
    });
    if (stopped_ || core_->stop || core_->decode_abort || core_->timeline != timeline) return 0;
    auto *copy = av_frame_clone(frame);
    if (!copy) return AVERROR(ENOMEM);
    queue_.push_back({copy, stream, hardware, timeline, static_cast<size_t>(cost)});
    bytes_ += cost;
    core_->wake.notify_all();
    return 0;
  }
  void Quiesce() {
    std::unique_lock lock(core_->mutex);
    enabled_ = false;
    Clear();
    core_->wake.notify_all();
    core_->wake.wait(lock, [&] { return !busy_; });
  }
  void Resume() {
    std::lock_guard lock(core_->mutex);
    enabled_ = true;
    core_->wake.notify_all();
  }
  void Drain(uint64_t timeline) {
    std::unique_lock lock(core_->mutex);
    core_->wake.wait(lock, [&] {
      return core_->stop || core_->decode_abort || core_->timeline != timeline ||
          (queue_.empty() && !busy_);
    });
  }
  void Stop() {
    {
      std::lock_guard lock(core_->mutex);
      stopped_ = true;
      Clear();
      core_->wake.notify_all();
    }
    if (thread_.joinable()) thread_.join();
  }
 private:
  struct Picture { AVFrame *frame; int stream; uint32_t hardware; uint64_t timeline; size_t cost; };
  void Clear() {
    for (auto &picture : queue_) av_frame_free(&picture.frame);
    queue_.clear();
    bytes_ = 0;
  }
  void Run() {
    for (;;) {
      Picture picture{};
      {
        std::unique_lock lock(core_->mutex);
        core_->wake.wait(lock, [&] {
          return stopped_ || core_->stop || core_->decode_abort ||
              (enabled_ && !queue_.empty() &&
               (queue_.front().timeline != core_->timeline ||
                core_->play_intent || !core_->first_video));
        });
        if (stopped_ || core_->stop || core_->decode_abort) break;
        picture = queue_.front();
        queue_.pop_front();
        bytes_ -= picture.cost;
        core_->wake.notify_all();
        if (picture.timeline != core_->timeline) {
          av_frame_free(&picture.frame);
          continue;
        }
        busy_ = true;
      }
      int result;
      try { result = convert_(picture.frame, picture.stream, picture.hardware, picture.timeline); }
      catch (...) { result = AVERROR_UNKNOWN; }
      av_frame_free(&picture.frame);
      bool failed = false;
      {
        std::lock_guard lock(core_->mutex);
        busy_ = false;
        if (result < 0 && picture.timeline == core_->timeline && !core_->stop) {
          int expected = 0;
          core_->decode_error.compare_exchange_strong(expected, result);
          core_->decode_abort = true;
          failed = true;
        }
        core_->wake.notify_all();
      }
      if (failed) { core_->io.cancel_media_io(core_->io.opaque); break; }
    }
  }
  RillightCoreImpl *core_;
  Convert convert_;
  std::thread thread_;
  std::deque<Picture> queue_;
  size_t bytes_ = 0;
  bool enabled_ = true, busy_ = false, stopped_ = false;
};


}  // namespace rillight::core
