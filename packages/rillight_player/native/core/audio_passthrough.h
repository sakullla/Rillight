#pragma once

#include "audio_contract.h"
#include "dts_burst.h"
#include <initializer_list>

// Encoded bytes cannot be scaled or muted. Decode when the application asks
// for software gain; hardware-controlled outputs keep the core gain at unity.
inline uint32_t rillight_audio_accept_for_gain(uint32_t accepted, double gain) {
  return gain == 1.0 ? accepted : 0;
}

// IEC carrier units are distinct from the decoded audio sample rate.
struct RillightAudioCarrier {
  int rate = 0;
  int channels = 0;
};

inline RillightAudioCarrier rillight_audio_carrier(int kind, int rate) {
  switch (kind) {
    case RILLIGHT_CORE_PASSTHROUGH_AC3:
    case RILLIGHT_CORE_PASSTHROUGH_DTS:
      return (rate == 32000 || rate == 44100 || rate == 48000)
                 ? RillightAudioCarrier{rate, 2} : RillightAudioCarrier{};
    case RILLIGHT_CORE_PASSTHROUGH_EAC3:
    case RILLIGHT_CORE_PASSTHROUGH_EAC3_JOC:
      return (rate == 32000 || rate == 44100 || rate == 48000)
                 ? RillightAudioCarrier{rate * 4, 2} : RillightAudioCarrier{};
    case RILLIGHT_CORE_PASSTHROUGH_TRUEHD:
      if (rate == 44100 || rate == 88200 || rate == 176400) return {176400, 8};
      if (rate == 48000 || rate == 96000 || rate == 192000) return {192000, 8};
      return {};
    case RILLIGHT_CORE_PASSTHROUGH_DTSHD:
      return (rate > 0) ? RillightAudioCarrier{192000, 8} : RillightAudioCarrier{};
    default: return {};
  }
}

// Matroska packet duration is often rounded to whole milliseconds: 40 TrueHD
// samples become zero and 512 DTS samples become 480. Never accumulate that
// rounded duration as a hardware sample count.
inline int rillight_passthrough_samples(int kind, const uint8_t* data,
                                       int size, int rate) {
  if (!data || size < 6 || rate <= 0) return 0;
  if (kind == RILLIGHT_CORE_PASSTHROUGH_AC3)
    return data[0] == 0x0b && data[1] == 0x77 && (data[5] >> 3) <= 10 ? 1536 : 0;
  if (kind == RILLIGHT_CORE_PASSTHROUGH_EAC3 ||
      kind == RILLIGHT_CORE_PASSTHROUGH_EAC3_JOC) {
    if (data[0] != 0x0b || data[1] != 0x77 || (data[5] >> 3) <= 10 ||
        (data[5] >> 3) > 16) return 0;
    constexpr int blocks[] = {1, 2, 3, 6};
    return 256 * ((data[4] >> 6) == 3 ? 6 : blocks[(data[4] >> 4) & 3]);
  }
  if (kind == RILLIGHT_CORE_PASSTHROUGH_TRUEHD) {
    if (size < 10) return 0;
    for (int base : {44100, 48000})
      for (int shift = 0; shift <= 2; ++shift)
        if (rate == (base << shift)) return 40 << shift;
    return 0;
  }
  if (kind == RILLIGHT_CORE_PASSTHROUGH_DTS ||
      kind == RILLIGHT_CORE_PASSTHROUGH_DTSHD) {
    const auto header = rillight_dts_header(data, size);
    if (!header.samples) return 0;
    if (!header.rate) return kind == RILLIGHT_CORE_PASSTHROUGH_DTS ? header.samples : 0;
    const int64_t scaled = int64_t(header.samples) * rate;
    return scaled % header.rate == 0 ? static_cast<int>(scaled / header.rate) : 0;
  }
  return 0;
}
