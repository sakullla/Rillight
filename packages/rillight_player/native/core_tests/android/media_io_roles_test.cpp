#include "media_io_roles.h"

#include <cassert>
#include <future>
#include <thread>

int main() {
  MediaIoRoles roles;
  // Root media, HLS playlist and segments are opened on the demux worker.
  const auto worker = std::this_thread::get_id();
  assert(roles.is_media(worker));
  assert(roles.is_media(worker));
  std::promise<bool> subtitle;
  std::thread loader([&] { subtitle.set_value(roles.is_media(std::this_thread::get_id())); });
  assert(!subtitle.get_future().get());
  loader.join();
  assert(roles.is_media(worker));
}
