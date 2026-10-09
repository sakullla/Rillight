#ifndef RILLIGHT_ANDROID_TUNNEL_H_
#define RILLIGHT_ANDROID_TUNNEL_H_

#include "rillight_core.h"
#include <cstdint>
#include <memory>
#include <vector>

// Internal platform sink contract. FFmpeg retains IO, demux, bitstream filtering,
// audio and subtitles. Each sink belongs to exactly one decoder timeline.
class AndroidTunnelSink {
 public:
  virtual ~AndroidTunnelSink() = default;
  // 1 accepted, 0 retry, negative failure. null data sends EOS.
  virtual int Queue(const uint8_t* data, int size, int64_t pts) = 0;
  virtual int64_t Rendered() = 0;
};

class AndroidTunnelFactory {
 public:
  virtual ~AndroidTunnelFactory() = default;
  virtual std::shared_ptr<AndroidTunnelSink> Open(void* window, int width,
      int height, int profile, int level, const std::vector<uint8_t>& csd,
      const std::vector<uint8_t>& config, int rate) = 0;
};

// Idle only; the core retains the factory until all decoder workers retire.
RILLIGHT_CORE_API int rillight_core_android_tunnel_factory(RillightCore* core,
    std::shared_ptr<AndroidTunnelFactory> factory, uint32_t profiles);
#endif
