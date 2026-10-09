#ifndef RILLIGHT_DTS_BURST_H_
#define RILLIGHT_DTS_BURST_H_

#include <cstdint>

// DTS core header fields used by IEC 61937 types I-IV. HD-only/Express
// packets are rejected so the caller decodes PCM instead of truncating audio.
struct RillightDtsHeader {
  int samples = 0;
  int core_bytes = 0;
  int rate = 0;
  bool little_endian = false;
  bool packed14 = false;
};

inline RillightDtsHeader rillight_dts_header(const uint8_t* data, int size) {
  if (!data || size < 10) return {};
  const uint32_t sync = (uint32_t(data[0]) << 24) | (uint32_t(data[1]) << 16) |
                        (uint32_t(data[2]) << 8) | data[3];
  RillightDtsHeader out;
  out.little_endian = sync == 0xfe7f0180u || sync == 0xff1f00e8u;
  out.packed14 = sync == 0x1fffe800u || sync == 0xff1f00e8u;
  if (sync != 0x7ffe8001u && sync != 0xfe7f0180u && !out.packed14) return {};
  auto byte = [&](int i) { return data[out.little_endian ? (i ^ 1) : i]; };
  int blocks;
  if (out.packed14) {
    blocks = ((byte(5) & 7) << 4) | ((byte(6) & 63) >> 2);
    out.core_bytes = (((byte(6) & 3) << 12) | (byte(7) << 4) |
                       (byte(8) >> 2 & 15)) + 1;
    out.core_bytes = out.core_bytes * 16 / 14;
  } else {
    blocks = ((byte(4) << 8 | byte(5)) >> 2) & 127;
    out.core_bytes = (((byte(5) & 3) << 12) | (byte(6) << 4) |
                       (byte(7) >> 4)) + 1;
    constexpr int rates[] = {0, 8000, 16000, 32000, 0, 0, 11025, 22050,
                            44100, 0, 0, 12000, 24000, 48000, 96000, 192000};
    out.rate = rates[(byte(8) >> 2) & 15];
  }
  out.samples = (blocks + 1) * 32;
  if (out.core_bytes < 10 || out.core_bytes > size ||
      (out.samples != 512 && out.samples != 1024 && out.samples != 2048))
    return {};
  return out;
}

inline int rillight_dtshd_period(const RillightDtsHeader& header) {
  if (!header.rate || header.packed14 || header.little_endian) return 0;
  const int frames = 768000 * header.samples / header.rate;
  for (int i = 512; i <= 16384; i *= 2)
    if (frames == i && 768000LL * header.samples == int64_t(i) * header.rate)
      return frames * 4;
  return 0;
}

#endif
