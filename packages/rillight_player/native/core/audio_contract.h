#ifndef RILLIGHT_AUDIO_CONTRACT_H_
#define RILLIGHT_AUDIO_CONTRACT_H_

#include "rillight_core.h"

#include <cstddef>
#include <cstdint>

// Sink acceptance describes the compressed format, independently of channel
// count. PCM sources and unaccepted formats never acquire a passthrough label.
inline uint32_t rillight_passthrough_accept_bit(int kind) {
  switch (kind) {
    case RILLIGHT_CORE_PASSTHROUGH_EAC3_JOC:
    case RILLIGHT_CORE_PASSTHROUGH_EAC3: return RILLIGHT_CORE_AUDIO_ACCEPT_EAC3;
    case RILLIGHT_CORE_PASSTHROUGH_TRUEHD: return RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD;
    case RILLIGHT_CORE_PASSTHROUGH_AC3: return RILLIGHT_CORE_AUDIO_ACCEPT_AC3;
    case RILLIGHT_CORE_PASSTHROUGH_DTS: return RILLIGHT_CORE_AUDIO_ACCEPT_DTS;
    case RILLIGHT_CORE_PASSTHROUGH_DTSHD: return RILLIGHT_CORE_AUDIO_ACCEPT_DTSHD;
    default: return 0;
  }
}

struct RillightAudioContract {
  int delivery;
  int channels;
  int layout;
  int passthrough;
  int atmos;
  const char *ffmpeg_layout;
};

inline int rillight_layout_for_channels(int channels) {
  if (channels >= 8) return RILLIGHT_CORE_CH_LAYOUT_7POINT1;
  if (channels >= 6) return RILLIGHT_CORE_CH_LAYOUT_5POINT1;
  if (channels == 1) return RILLIGHT_CORE_CH_LAYOUT_MONO;
  if (channels >= 2) return RILLIGHT_CORE_CH_LAYOUT_STEREO;
  return RILLIGHT_CORE_CH_LAYOUT_NONE;
}

inline RillightAudioContract rillight_audio_contract(
    int source_channels, int passthrough_kind, int max_pcm_channels,
    uint32_t accepted, int reports_atmos, double speed) {
  RillightAudioContract out{};
  out.ffmpeg_layout = "stereo";
  out.channels = 2;
  out.layout = RILLIGHT_CORE_CH_LAYOUT_STEREO;
  out.delivery = RILLIGHT_CORE_AUDIO_DELIVERY_PCM_STEREO;
  const int device = max_pcm_channels < 1 ? 2 : max_pcm_channels;
  const int speed_ok = speed > 0.999 && speed < 1.001;
  const bool accepted_format =
      (accepted & rillight_passthrough_accept_bit(passthrough_kind)) != 0;
  if (accepted_format && speed_ok) {
    const int channels = source_channels > 0 ? source_channels : 2;
    out.delivery = RILLIGHT_CORE_AUDIO_DELIVERY_PASSTHROUGH;
    out.passthrough = 1;
    out.atmos = reports_atmos &&
        (passthrough_kind == RILLIGHT_CORE_PASSTHROUGH_EAC3_JOC ||
         passthrough_kind == RILLIGHT_CORE_PASSTHROUGH_TRUEHD) ? 1 : 0;
    out.channels = channels;
    out.layout = rillight_layout_for_channels(channels);
    out.ffmpeg_layout = nullptr;
    return out;
  }
  if (source_channels <= 2) return out;
  if (device >= 8 && source_channels >= 8) {
    out.delivery = RILLIGHT_CORE_AUDIO_DELIVERY_PCM_MULTICHANNEL;
    out.channels = 8;
    out.layout = RILLIGHT_CORE_CH_LAYOUT_7POINT1;
    out.ffmpeg_layout = "7.1";
    return out;
  }
  if (device >= 6 && source_channels >= 6) {
    out.delivery = RILLIGHT_CORE_AUDIO_DELIVERY_PCM_MULTICHANNEL;
    out.channels = 6;
    out.layout = RILLIGHT_CORE_CH_LAYOUT_5POINT1;
    out.ffmpeg_layout = "5.1";
    return out;
  }
  out.delivery = RILLIGHT_CORE_AUDIO_DELIVERY_PCM_DOWNMIX;
  return out;
}

// E-AC-3 additional bitstream info, flag_ec3_extension_type_a. A parse failure
// is not JOC: the caller decodes PCM instead of inventing a passthrough.
inline bool rillight_eac3_frame_is_joc(const uint8_t *data, int size) {
  struct Bits {
    const uint8_t *bytes;
    int size;
    int bit = 0;
    bool ok = true;
    int get(int count) {
      if (!ok || count < 0 || count > 31 || bit + count > size * 8) {
        ok = false;
        return 0;
      }
      unsigned value = 0;
      for (int index = 0; index < count; ++index) {
        const int position = bit++;
        const int shift = 7 - (position & 7);
        value = (value << 1) | ((bytes[position >> 3] >> shift) & 1);
      }
      return value;
    }
    void skip(int count) { get(count); }
    int show(int count) const {
      Bits copy = *this;
      return copy.get(count);
    }
  };
  if (!data || size < 7) return false;
  Bits bits{data, size};
  if (bits.get(16) != 0x0B77) return false;
  const int bsid = bits.show(29) & 0x1F;
  if (bsid <= 10 || bsid > 16) return false;
  const int frame_type = bits.get(2);
  if (frame_type == 3) return false;
  if (bits.get(3) != 0) return false;
  const int frame_size = (bits.get(11) + 1) << 1;
  if (frame_size < 7 || frame_size > size) return false;
  const int sr_code = bits.get(2);
  int num_blocks = 6;
  if (sr_code == 3) {
    if (bits.get(2) == 3) return false;
  } else {
    static const int blocks[4] = {1, 2, 3, 6};
    num_blocks = blocks[bits.get(2)];
  }
  const int channel_mode = bits.get(3);
  const int lfe = bits.get(1);
  bits.skip(5);
  const int programs = channel_mode ? 1 : 2;
  for (int program = 0; program < programs; ++program) {
    bits.skip(5);
    if (bits.get(1)) bits.skip(8);
  }
  if (frame_type == 1 && bits.get(1)) bits.skip(16);
  if (bits.get(1)) {
    if (channel_mode > 2) {
      bits.skip(2);
      if (channel_mode & 1) bits.skip(6);
      if (channel_mode & 4) bits.skip(6);
    }
    if (lfe && bits.get(1)) bits.skip(5);
    if (frame_type == 0) {
      for (int program = 0; program < programs; ++program) {
        if (bits.get(1)) bits.skip(6);
      }
      if (bits.get(1)) bits.skip(6);
      switch (bits.get(2)) {
        case 1:
          bits.skip(5);
          break;
        case 2:
          bits.skip(12);
          break;
        case 3:
          bits.skip((bits.get(5) + 2) << 3);
          break;
        default:
          break;
      }
      if (channel_mode < 2) {
        for (int program = 0; program < programs; ++program) {
          if (bits.get(1)) bits.skip(14);
        }
      }
      if (bits.get(1)) {
        for (int block = 0; block < num_blocks; ++block) {
          if (num_blocks == 1 || bits.get(1)) bits.skip(5);
        }
      }
    }
  }
  if (bits.get(1)) {
    bits.skip(5);
    if (channel_mode == 2) bits.skip(4);
    if (channel_mode >= 6) bits.skip(2);
    for (int program = 0; program < programs; ++program) {
      if (bits.get(1)) bits.skip(8);
    }
    if (sr_code != 3) bits.skip(1);
  }
  if (frame_type == 0 && num_blocks != 6) bits.skip(1);
  if (frame_type == 2 && (num_blocks == 6 || bits.get(1))) bits.skip(6);
  if (!bits.ok || !bits.get(1)) return false;
  const int addbsil = bits.get(6);
  bool joc = false;
  for (int index = 0; index < addbsil + 1; ++index) {
    if (index == 0) {
      bits.skip(7);
      joc = bits.get(1) == 1;
      if (joc) {
        bits.skip(8);
        ++index;
      }
    } else {
      bits.skip(8);
    }
    if (!bits.ok) return false;
  }
  return bits.ok && joc;
}

#endif
