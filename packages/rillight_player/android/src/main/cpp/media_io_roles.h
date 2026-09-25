#ifndef RILLIGHT_ANDROID_MEDIA_IO_ROLES_H_
#define RILLIGHT_ANDROID_MEDIA_IO_ROLES_H_

#include <thread>

// Protected by the caller's source registry mutex. The core media worker opens
// the root demuxer before any external subtitle loader may be started. FFmpeg
// opens HLS playlists, segments and keys on that same media worker thread.
class MediaIoRoles {
 public:
  bool is_media(std::thread::id opener) {
    if (media_worker_ == std::thread::id{}) media_worker_ = opener;
    return opener == media_worker_;
  }

 private:
  std::thread::id media_worker_;
};

#endif
