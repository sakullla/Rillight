#pragma once

#include "core_common.h"

namespace rillight::core {
struct LoopbackIo {
  std::atomic<uint64_t> media_generation{0};
  std::atomic<uint64_t> next_input_id{1};
  std::atomic<int> media_open_error{0};
  std::atomic<bool> closing{false};
  std::mutex thread_mutex;
  std::thread::id media_thread;
};

struct LoopbackHandle {
  LoopbackIo *owner;
  uint64_t input_id = 0;
  AVIOContext *io = nullptr;
  std::string url;
  int64_t position = 0;
  bool media = false;
  std::atomic<uint64_t> read_generation{0};
  uint64_t open_generation = 0;
};

struct Source {
  RillightCoreIo io;
  std::atomic<int> *fatal_error = nullptr;
  std::atomic<uint64_t> *timeline_signal = nullptr;
  std::atomic<uint64_t> *active_read_timeline = nullptr;
  void *handle = nullptr;
  AVIOContext *avio = nullptr;
  AVAES *aes = nullptr;
  std::array<uint8_t, 16> initial_iv{};
  std::array<uint8_t, 16> iv{};
  std::vector<uint8_t> ciphertext;
  std::vector<uint8_t> plaintext;
  size_t ciphertext_size = 0;
  size_t plaintext_size = 0;
  size_t plaintext_offset = 0;
  int64_t position = 0;
  bool encrypted_eof = false;
};

struct RillightCoreImpl;
// core_loopback.cpp
bool sealed_loopback_url(const char *url);
int loopback_interrupted(void *opaque);
int loopback_open_at(LoopbackHandle *handle, int64_t position);
void *loopback_open(void *opaque, const char *url, int flags);
int loopback_read(void *, void *pointer, uint8_t *data, int size);
int64_t loopback_seek(void *, void *pointer, int64_t offset, int whence);
void loopback_close(void *, void *pointer);
void loopback_cancel(void *opaque);
void loopback_cancel_media(void *opaque);
// core_io.cpp
int interrupt_read(void *opaque);
int fill_decrypted(Source *source);
int source_read(void *opaque, uint8_t *buffer, int size);
int64_t source_seek(void *opaque, int64_t offset, int whence);
Source *open_source(RillightCoreImpl *core, const char *url, int flags);
void close_source(Source *source);
bool parse_aes_hex(const char *hex, uint8_t *bytes);
int nested_open(AVFormatContext *format, AVIOContext **avio,
                const char *url, int flags, AVDictionary **options);
int nested_close(AVFormatContext *, AVIOContext *avio);
}  // namespace rillight::core
