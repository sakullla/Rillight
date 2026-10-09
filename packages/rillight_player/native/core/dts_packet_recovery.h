#pragma once

// Isolated corrupt DTS access units must not terminate the video lane. Bound
// recovery so a wholly invalid track still reports a decoding failure.
class DtsPacketRecovery {
 public:
  bool skipInvalidPacket() { return ++invalid_packets_ <= 8; }
  void reset() { invalid_packets_ = 0; }
 private:
  unsigned int invalid_packets_ = 0;
};
