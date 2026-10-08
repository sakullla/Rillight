#include "../cache/directory.c"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
  char root[1024];
  snprintf(root, sizeof(root), "%s/rillight-directory-XXXXXX", argc > 1 ? argv[1] : "/tmp");
  assert(mkdtemp(root));
  char file[1100], link[1100], child[1100];
  snprintf(file, sizeof(file), "%s/actual-1-deadbeef.block", root);
  snprintf(link, sizeof(link), "%s/link", root);
  snprintf(child, sizeof(child), "%s/child", root);
  int fd = open(file, O_CREAT | O_RDWR, 0600);
  assert(fd >= 0);
  /* ARM32 must account for sparse files larger than 4 GiB without truncation. */
  const int64_t size = INT64_C(5) * 1024 * 1024 * 1024 + 17;
  assert(ftruncate(fd, size) == 0);
  assert(symlink(file, link) == 0);
  assert(mkdir(child, 0700) == 0);
  RillightDirectoryEntry entries[3];
  assert(rillight_read_directory(root, entries, 2) < 0);
  assert(rillight_read_directory(root, entries, 3) == 3);
  int files = 0, links = 0, directories = 0;
  struct stat expected;
  assert(fstat(fd, &expected) == 0);
  for (int i = 0; i < 3; i++) {
    if (entries[i].kind == 1) {
      files++;
      assert(entries[i].size == size);
#if defined(__APPLE__)
      assert(entries[i].changed_us == (int64_t)expected.st_ctimespec.tv_sec * 1000000 + expected.st_ctimespec.tv_nsec / 1000);
#else
      assert(entries[i].changed_us == (int64_t)expected.st_ctim.tv_sec * 1000000 + expected.st_ctim.tv_nsec / 1000);
#endif
    }
    if (entries[i].kind == 2) directories++;
    if (entries[i].kind == 3) links++;
  }
  assert(files == 1 && links == 1 && directories == 1);
  assert(ftruncate(fd, 7) == 0);
  close(fd);
  assert(rillight_read_directory(root, entries, 3) == 3);
  for (int i = 0; i < 3; i++) if (entries[i].kind == 1) assert(entries[i].size == 7);
  assert(rillight_read_directory(link, entries, 3) < 0);
  assert(unlink(link) == 0);
  assert(unlink(file) == 0);
  assert(rmdir(child) == 0);
  assert(rillight_read_directory(root, entries, 0) == 0);
  assert(rmdir(root) == 0);
  puts("cache directory: passed");
  return 0;
}
