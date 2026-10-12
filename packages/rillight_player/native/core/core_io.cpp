#include "core_state.h"

namespace rillight::core {
int interrupt_read(void *opaque) {
  auto *core = static_cast<RillightCoreImpl *>(opaque);
  return core->stop.load() || core->decode_abort.load() ||
         core->timeline_signal.load() != core->active_read_timeline.load();
}

int fill_decrypted(Source *source) {
  if (source->encrypted_eof && !source->ciphertext_size)
    return AVERROR_EOF;
  while (!source->encrypted_eof && source->ciphertext_size < 32) {
    const int capacity = static_cast<int>(source->ciphertext.size() -
                                          source->ciphertext_size);
    const int read = source->io.read(source->io.opaque, source->handle,
                                     source->ciphertext.data() +
                                         source->ciphertext_size,
                                     capacity);
    if (read > capacity) return AVERROR(EIO);
    if (read < 0) return read;
    if (read == 0) {
      source->encrypted_eof = true;
      break;
    }
    source->ciphertext_size += read;
  }
  if (source->encrypted_eof &&
      (source->ciphertext_size == 0 || source->ciphertext_size % 16 != 0))
    return AVERROR_INVALIDDATA;
  size_t blocks = source->ciphertext_size / 16;
  if (!source->encrypted_eof) --blocks;  // Keep the final block for PKCS#7.
  if (!blocks) return AVERROR(EAGAIN);
  const size_t decrypted_size = blocks * 16;
  av_aes_crypt(source->aes, source->plaintext.data(),
               source->ciphertext.data(), static_cast<int>(blocks),
               source->iv.data(), 1);
  source->plaintext_size = decrypted_size;
  source->plaintext_offset = 0;
  if (source->encrypted_eof) {
    const uint8_t padding = source->plaintext[decrypted_size - 1];
    if (padding == 0 || padding > 16 ||
        !std::all_of(source->plaintext.data() + decrypted_size - padding,
                     source->plaintext.data() + decrypted_size,
                     [padding](uint8_t byte) { return byte == padding; }))
      return AVERROR_INVALIDDATA;
    source->plaintext_size -= padding;
  }
  source->ciphertext_size -= decrypted_size;
  if (source->ciphertext_size)
    std::memmove(source->ciphertext.data(),
                 source->ciphertext.data() + decrypted_size,
                 source->ciphertext_size);
  return source->plaintext_size ? 0 : AVERROR_EOF;
}

int source_read(void *opaque, uint8_t *buffer, int size) {
  auto *source = static_cast<Source *>(opaque);
  const uint64_t read_timeline = source->timeline_signal->load();
  const auto record_error = [source, read_timeline](int result) {
    if (result < 0 && result != AVERROR_EOF &&
        result != AVERROR(EAGAIN) && result != AVERROR_EXIT &&
        source->timeline_signal->load() == read_timeline &&
        source->active_read_timeline->load() == read_timeline) {
      int expected = 0;
      source->fatal_error->compare_exchange_strong(expected, result);
    }
    return result;
  };
  if (!source->aes) {
    const int result = source->io.read(source->io.opaque, source->handle,
                                       buffer, size);
    if (result > size) return record_error(AVERROR(EIO));
    return record_error(result == 0 ? AVERROR_EOF : result);
  }
  int copied = 0;
  while (copied < size) {
    if (source->plaintext_offset == source->plaintext_size) {
      const int result = fill_decrypted(source);
      if (result < 0) {
        record_error(result);
        return copied ? copied : result;
      }
    }
    const size_t count = std::min<size_t>(
        size - copied, source->plaintext_size - source->plaintext_offset);
    std::memcpy(buffer + copied,
                source->plaintext.data() + source->plaintext_offset, count);
    copied += static_cast<int>(count);
    source->plaintext_offset += count;
    source->position += count;
  }
  return copied;
}

int64_t source_seek(void *opaque, int64_t offset, int whence) {
  auto *source = static_cast<Source *>(opaque);
  if (!source->aes) {
    const auto timeline = source->timeline_signal->load();
    const int64_t result = source->io.seek(source->io.opaque, source->handle, offset, whence);
    if (!(whence & AVSEEK_SIZE) && result < 0 && result != AVERROR(ENOSYS) &&
        result != AVERROR(EAGAIN) && result != AVERROR_EXIT &&
        source->timeline_signal->load() == timeline &&
        source->active_read_timeline->load() == timeline) {
      int expected = 0;
      source->fatal_error->compare_exchange_strong(expected, static_cast<int>(result));
    }
    return result;
  }
  if (whence == AVSEEK_SIZE)
    return source->io.seek(source->io.opaque, source->handle, offset, whence);
  if (whence == SEEK_CUR && offset == 0) return source->position;
  // AES-CBC with PKCS#7 allows no arbitrary back seek without refetching, but
  // a bounded forward skip is exactly a read-and-discard. Probing re-reads
  // forward inside segments (fMP4 init + data), so refusing it broke opens.
  {
    constexpr int64_t kMaxAesForwardSkip = 2 * 1024 * 1024;
    int64_t skip = -1;
    if (whence == SEEK_CUR && offset > 0) skip = offset;
    else if (whence == SEEK_SET && offset > source->position)
      skip = offset - source->position;
    if (skip >= 0 && skip <= kMaxAesForwardSkip) {
      uint8_t discard[16384];
      while (skip > 0) {
        const int want =
            static_cast<int>(std::min<int64_t>(skip, sizeof(discard)));
        const int read = source_read(opaque, discard, want);
        if (read < 0) return read;
        if (read == 0) return AVERROR_EOF;
        skip -= read;
      }
      return source->position;
    }
  }
  if (whence != SEEK_SET || offset != 0) return AVERROR(ENOSYS);
  const int64_t target = source->io.seek(source->io.opaque, source->handle,
                                         0, SEEK_SET);
  if (target != 0) return target < 0 ? target : AVERROR(EIO);
  source->iv = source->initial_iv;
  source->ciphertext_size = 0;
  source->plaintext_size = 0;
  source->plaintext_offset = 0;
  source->position = 0;
  source->encrypted_eof = false;
  return 0;
}

Source *open_source(RillightCoreImpl *core, const char *url, int flags) {
  auto source = std::make_unique<Source>();
  source->io = core->io;
  source->fatal_error = &core->io_fatal_error;
  source->timeline_signal = &core->timeline_signal;
  source->active_read_timeline = &core->active_read_timeline;
  source->handle = core->io.open(core->io.opaque, url, flags);
  if (!source->handle) return nullptr;
  auto *buffer = static_cast<unsigned char *>(av_malloc(kIoBufferSize));
  if (!buffer) {
    core->io.close(core->io.opaque, source->handle);
    return nullptr;
  }
  source->avio = avio_alloc_context(buffer, kIoBufferSize, 0, source.get(),
                                    source_read, nullptr, source_seek);
  if (!source->avio) {
    av_free(buffer);
    core->io.close(core->io.opaque, source->handle);
    return nullptr;
  }
  return source.release();
}

void close_source(Source *source) {
  if (!source) return;
  if (source->avio) {
    av_freep(&source->avio->buffer);
    avio_context_free(&source->avio);
  }
  source->io.close(source->io.opaque, source->handle);
  av_free(source->aes);
  delete source;
}

bool parse_aes_hex(const char *hex, uint8_t *bytes) {
  if (!hex || std::strlen(hex) != 32) return false;
  const auto digit = [](char value) -> int {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    return -1;
  };
  for (int index = 0; index < 16; ++index) {
    const int high = digit(hex[index * 2]);
    const int low = digit(hex[index * 2 + 1]);
    if (high < 0 || low < 0) return false;
    bytes[index] = static_cast<uint8_t>((high << 4) | low);
  }
  return true;
}

int nested_open(AVFormatContext *format, AVIOContext **avio,
                const char *url, int flags, AVDictionary **options) {
  auto *core = static_cast<RillightCoreImpl *>(format->opaque);
  const bool encrypted = std::strncmp(url, "crypto+", 7) == 0;
  if (encrypted && (flags & AVIO_FLAG_WRITE)) return AVERROR(EACCES);
  std::array<uint8_t, 16> key{};
  std::array<uint8_t, 16> iv{};
  if (encrypted) {
    const auto *key_option = options && *options
        ? av_dict_get(*options, "key", nullptr, 0) : nullptr;
    const auto *iv_option = options && *options
        ? av_dict_get(*options, "iv", nullptr, 0) : nullptr;
    if (!key_option || !iv_option ||
        !parse_aes_hex(key_option->value, key.data()) ||
        !parse_aes_hex(iv_option->value, iv.data()))
      return AVERROR_INVALIDDATA;
  }
  auto *source = open_source(core, encrypted ? url + 7 : url, flags);
  if (!source) return AVERROR(EACCES);
  if (encrypted) {
    source->aes = av_aes_alloc();
    if (!source->aes || av_aes_init(source->aes, key.data(), 128, 1) < 0) {
      close_source(source);
      return AVERROR(ENOMEM);
    }
    source->initial_iv = iv;
    source->iv = iv;
    source->ciphertext.resize(kIoBufferSize + 16);
    source->plaintext.resize(kIoBufferSize + 16);
    source->avio->seekable = 0;
  }
  *avio = source->avio;
  return 0;
}

int nested_close(AVFormatContext *, AVIOContext *avio) {
  close_source(static_cast<Source *>(avio->opaque));
  return 0;
}
}  // namespace rillight::core
