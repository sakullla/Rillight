#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <string.h>

typedef struct {
  int64_t size;
  int64_t modified_us;
  int64_t changed_us;
  int32_t kind; /* 1 file, 2 directory, 3 link, 4 other */
  char name[256];
} RillightDirectoryEntry;

#if defined(_WIN32)
__declspec(dllexport) int32_t rillight_read_directory(
    const char *path, RillightDirectoryEntry *entries, int32_t capacity) {
  return -1; /* Windows uses FindFirstFile, which already supplies metadata. */
}
#else
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

/* One bounded native call, no Dart allocation or synchronous I/O dispatch per
 * file. Never follow links and never return a partial quota inventory. */
__attribute__((visibility("default"))) int32_t rillight_read_directory(
    const char *path, RillightDirectoryEntry *entries, int32_t capacity) {
  if (!path || !entries || capacity < 0) return -EINVAL;
  int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return -errno;
  DIR *dir = fdopendir(fd);
  if (!dir) { int error = errno; close(fd); return -error; }
  int32_t count = 0, result = 0;
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(dir);
    if (!entry) { result = errno ? -errno : count; break; }
    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
    if (count == capacity) { result = -EOVERFLOW; break; }
    size_t length = strlen(entry->d_name);
    if (length >= sizeof(entries[count].name)) { result = -ENAMETOOLONG; break; }
    struct stat st;
    if (fstatat(fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW)) {
      result = -errno; break;
    }
    RillightDirectoryEntry *out = &entries[count++];
    out->size = st.st_size;
#if defined(__APPLE__)
    out->modified_us = (int64_t)st.st_mtimespec.tv_sec * 1000000 + st.st_mtimespec.tv_nsec / 1000;
    out->changed_us = (int64_t)st.st_ctimespec.tv_sec * 1000000 + st.st_ctimespec.tv_nsec / 1000;
#else
    out->modified_us = (int64_t)st.st_mtim.tv_sec * 1000000 + st.st_mtim.tv_nsec / 1000;
    out->changed_us = (int64_t)st.st_ctim.tv_sec * 1000000 + st.st_ctim.tv_nsec / 1000;
#endif
    out->kind = S_ISREG(st.st_mode) ? 1 : S_ISDIR(st.st_mode) ? 2 : S_ISLNK(st.st_mode) ? 3 : 4;
    memcpy(out->name, entry->d_name, length + 1);
  }
  closedir(dir);
  return result;
}
#endif
