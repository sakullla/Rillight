#include "../../../linux/audio_route.h"
#include <cassert>

int main() {
  rillight_linux::AudioRoutePolicy route;
  route.Observe("hdmi", 8, 3);
  route.Reject(RILLIGHT_CORE_PASSTHROUGH_EAC3);
  assert(route.accepted() == 2);
  route.Observe("hdmi", 8, 3); // volume/stream notification
  assert(route.accepted() == 2);
  route.Observe("headphones", 2, 0);
  assert(route.accepted() == 0);
  route.Observe("hdmi", 8, 3);
  assert(route.accepted() == 3);
  route.Reject(RILLIGHT_CORE_PASSTHROUGH_TRUEHD);
  assert(route.accepted() == 1);
  route.Observe("hdmi", 2, 1); // profile capabilities changed
  assert(route.accepted() == 1);
  return 0;
}
