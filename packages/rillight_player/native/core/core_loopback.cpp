#include "core_io.h"

namespace rillight::core {
bool sealed_loopback_url(const char *url) {
  if (!url) return false;
  constexpr std::string_view prefix = "http://127.0.0.1:";
  const std::string_view value(url);
  if (value.size() < prefix.size() || value.substr(0, prefix.size()) != prefix)
    return false;
  size_t offset = prefix.size();
  const size_t port_start = offset;
  while (offset < value.size() && value[offset] >= '0' &&
         value[offset] <= '9') ++offset;
  return offset > port_start && offset - port_start <= 5 &&
         offset < value.size() && value[offset] == '/' &&
         value.find('@') == std::string_view::npos &&
         value.find('\\') == std::string_view::npos;
}

int loopback_interrupted(void *opaque) {
  const auto *handle = static_cast<LoopbackHandle *>(opaque);
  return handle->owner->closing.load() ||
         (handle->media && handle->read_generation.load() !=
                               handle->owner->media_generation.load());
}

int loopback_open_at(LoopbackHandle *handle, int64_t position) {
  if (handle->owner->closing.load() || !sealed_loopback_url(handle->url.c_str()))
    return AVERROR_EXIT;
  const uint64_t generation = handle->owner->media_generation.load();
  AVDictionary *options = nullptr;
  // The local proxy allows 20 s for upstream headers and owns network recovery.
  // A shorter loopback timeout aborts a healthy in-flight request first. The
  // 45 s application open deadline and interrupt callback still bound/cancel it.
  av_dict_set(&options, "rw_timeout", "45000000", 0);
  // Every reconnect must retain the same sealed route and redirect policy.
  av_dict_set(&options, "max_redirects", "0", 0);
  // Each AVIO input performs sequential range reads. Preserve its identity
  // across HTTP seeks so the proxy can retire its previous response before
  // admitting the replacement, without cancelling other track readers.
  const std::string headers = "X-Rillight-Input-Id: " +
      std::to_string(handle->input_id) + "\r\n";
  av_dict_set(&options, "headers", headers.c_str(), 0);
  // Reopening after cancellation must request the target directly. Opening at
  // byte zero first creates an obsolete header request beside the media read.
  if (position > 0) av_dict_set_int(&options, "offset", position, 0);
  const AVIOInterruptCB interrupt{loopback_interrupted, handle};
  AVIOContext *replacement = nullptr;
  // Retire the old response before requesting a new range. A warm-prefix
  // response can still own the proxy's sole origin connection; opening the
  // replacement first then waits for headers that cannot arrive until this
  // old consumer closes. This handle is owned by the calling demux thread.
  if (handle->io) avio_closep(&handle->io);
  int result = avio_open2(&replacement, handle->url.c_str(), AVIO_FLAG_READ,
                          &interrupt, &options);
  av_dict_free(&options);
  if (result < 0) return result;
  // HTTP's offset option already positions the protocol at this byte. The
  // newly allocated AVIO buffer still starts at logical zero; a small avio_seek
  // would consume the offset again rather than repositioning the protocol.
  replacement->pos = position;
  if (handle->media && handle->owner->media_generation.load() != generation) {
    avio_closep(&replacement);
    return AVERROR_EXIT;
  }
  handle->io = replacement;
  handle->position = position;
  handle->open_generation = generation;
  return 0;
}

void *loopback_open(void *opaque, const char *url, int flags) {
  auto *owner = static_cast<LoopbackIo *>(opaque);
  if (!owner || owner->closing.load() || !sealed_loopback_url(url) ||
      !(flags & AVIO_FLAG_READ) || (flags & AVIO_FLAG_WRITE)) return nullptr;
  auto handle = std::make_unique<LoopbackHandle>();
  handle->owner = owner;
  handle->input_id = owner->next_input_id.fetch_add(1);
  handle->url = url;
  {
    std::lock_guard lock(owner->thread_mutex);
    if (owner->media_thread == std::thread::id())
      owner->media_thread = std::this_thread::get_id();
    handle->media = owner->media_thread == std::this_thread::get_id();
  }
  handle->read_generation = owner->media_generation.load();
  const int result = loopback_open_at(handle.get(), 0);
  if (handle->media) owner->media_open_error = result < 0 ? result : 0;
  if (result < 0) return nullptr;
  return handle.release();
}

int loopback_read(void *, void *pointer, uint8_t *data, int size) {
  auto *handle = static_cast<LoopbackHandle *>(pointer);
  if (!handle || size <= 0) return AVERROR(EINVAL);
  const uint64_t generation = handle->owner->media_generation.load();
  handle->read_generation = generation;
  if (!handle->io ||
      (handle->media && handle->open_generation != generation)) {
    const int reopened = loopback_open_at(handle, handle->position);
    if (reopened < 0) return reopened;
  }
  // This is an AVIO read callback, not a request to fill the caller's buffer.
  // Container probing can grow that buffer to 16 MiB for seek-back. Filling
  // it eagerly re-downloads megabytes on every interleaved track seek.
  int result = avio_read_partial(handle->io, data, size);
  if (result > 0) handle->position += result;
  if (result == AVERROR(EIO) && !handle->owner->closing.load() &&
      handle->owner->media_generation.load() == generation &&
      loopback_open_at(handle, handle->position) == 0) {
    result = avio_read_partial(handle->io, data, size);
    if (result > 0) handle->position += result;
  }
  return result;
}

int64_t loopback_seek(void *, void *pointer, int64_t offset, int whence) {
  auto *handle = static_cast<LoopbackHandle *>(pointer);
  if (!handle) return AVERROR(EINVAL);
  const uint64_t generation = handle->owner->media_generation.load();
  const bool interrupted = !handle->io || handle->open_generation != generation;
  handle->read_generation = generation;
  // A newer timeline can interrupt avio_open2 after the old socket is closed.
  // That leaves the handle alive without an AVIO context. The next operation
  // must reopen it instead of making every future read/seek fail with EINVAL.
  if (whence & AVSEEK_SIZE) {
    if (!handle->io) {
      const int reopened = loopback_open_at(handle, handle->position);
      if (reopened < 0) return reopened;
    }
    return avio_size(handle->io);
  }
  // An interrupted HTTP read may leave FFmpeg's nested AVIO in an error
  // state. Seek on a fresh sealed route instead of reusing that connection.
  if (interrupted && (whence & ~AVSEEK_FORCE) == SEEK_SET && offset >= 0) {
    const int reopened = loopback_open_at(handle, offset);
    return reopened < 0 ? reopened : offset;
  }
  if (!handle->io) {
    const int reopened = loopback_open_at(handle, handle->position);
    if (reopened < 0) return reopened;
  }
  const int64_t result = avio_seek(handle->io, offset, whence & ~AVSEEK_FORCE);
  if (result >= 0) handle->position = result;
  return result;
}

void loopback_close(void *, void *pointer) {
  auto *handle = static_cast<LoopbackHandle *>(pointer);
  if (!handle) return;
  if (handle->io) avio_closep(&handle->io);
  delete handle;
}

void loopback_cancel(void *opaque) {
  auto *owner = static_cast<LoopbackIo *>(opaque);
  owner->closing = true;
  ++owner->media_generation;
}

void loopback_cancel_media(void *opaque) {
  auto *owner = static_cast<LoopbackIo *>(opaque);
  ++owner->media_generation;
}
}  // namespace rillight::core
