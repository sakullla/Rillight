#include "../core/dts_packet_recovery.h"
#include <cassert>

int main() {
  DtsPacketRecovery recovery;
  assert(recovery.skipInvalidPacket());
  recovery.reset(); // A decoded frame ends the corruption run.
  for (int i = 0; i < 8; ++i) assert(recovery.skipInvalidPacket());
  assert(!recovery.skipInvalidPacket());
  assert(!recovery.skipInvalidPacket());
  recovery.reset(); // A seek starts a new decoder timeline.
  assert(recovery.skipInvalidPacket());
}
