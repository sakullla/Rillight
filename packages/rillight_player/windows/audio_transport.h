#pragma once

#include "../native/core/audio_contract.h"

namespace rillight_windows {
struct IecTransport {
  int rate = 0;
  int channels = 0;
  int period_bytes = 0;
};

inline IecTransport EncodedTransport(int kind, int rate, int samples = 512) {
  if (rate != 32000 && rate != 44100 && rate != 48000 &&
      rate != 88200 && rate != 96000 && rate != 176400 && rate != 192000) return {};
  switch (kind) {
    case RILLIGHT_CORE_PASSTHROUGH_AC3:
      return rate <= 48000 ? IecTransport{rate, 2, 6144} : IecTransport{};
    case RILLIGHT_CORE_PASSTHROUGH_EAC3:
    case RILLIGHT_CORE_PASSTHROUGH_EAC3_JOC:
      return rate <= 48000 ? IecTransport{rate * 4, 2, 24576} : IecTransport{};
    case RILLIGHT_CORE_PASSTHROUGH_TRUEHD:
      // MAT framing here uses the 48 kHz family, not a resampled bitstream.
      return rate % 48000 == 0 ? IecTransport{192000, 8, 61440} : IecTransport{};
    case RILLIGHT_CORE_PASSTHROUGH_DTS:
      if (samples == 512 || samples == 1024 || samples == 2048)
        return {rate, 2, samples * 4};
      return {};
    case RILLIGHT_CORE_PASSTHROUGH_DTSHD: {
      if (samples != 512 && samples != 1024 && samples != 2048) return {};
      for (int frames = 512; frames <= 16384; frames *= 2)
        if (768000LL * samples == int64_t(frames) * rate)
          return {192000, 8, frames * 4};
      return {};
    }
    default: return {};
  }
}
}  // namespace rillight_windows
