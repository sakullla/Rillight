#pragma once

#include <cstdint>

#include "../native/core/rillight_core.h"

namespace rillight_windows {

// Thrown-away exclusive probes and the live stream share one classification.
// DEVICE_IN_USE means this process or another client still holds the endpoint;
// it is not evidence that the receiver rejected E-AC-3 or TrueHD.
enum class ExclusiveProbe : int {
  kAccepted = 0,
  kUnsupported = 1,
  kDeviceInUse = 2,
};

enum class ExclusiveStep : int {
  kContinue = 0,
  kUnsupported = 1,
  kDeviceInUse = 2,
};

struct RouteObservation {
  bool endpoint_present = false;
  bool device_in_use = false;
  bool mix_known = false;
  int mix_channels = 0;
  ExclusiveProbe eac3 = ExclusiveProbe::kUnsupported;
  ExclusiveProbe truehd = ExclusiveProbe::kUnsupported;
};

struct RouteCommit {
  bool publish = false;
  int max_pcm_channels = 2;
  uint32_t accepted_passthrough = 0;
};

inline int PcmChannelTarget(int channels) {
  if (channels >= 8) return 8;
  if (channels >= 6) return 6;
  return 2;
}

inline bool ExclusiveFormatRejected(int32_t hr) {
  switch (static_cast<uint32_t>(hr)) {
    case 1u:           // S_FALSE: exclusive format is not supported.
    case 0x80070057u:  // E_INVALIDARG
    case 0x88890006u:  // AUDCLNT_E_BUFFER_TOO_LARGE
    case 0x88890008u:  // AUDCLNT_E_UNSUPPORTED_FORMAT
    case 0x88890009u:  // AUDCLNT_E_INVALID_SIZE
    case 0x8889000Eu:  // AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED
    case 0x88890013u:  // AUDCLNT_E_BUFDURATION_PERIOD_NOT_EQUAL
    case 0x88890015u:  // AUDCLNT_E_INCORRECT_BUFFER_SIZE
    case 0x88890016u:  // AUDCLNT_E_BUFFER_SIZE_ERROR
    case 0x88890018u:  // AUDCLNT_E_BUFFER_ERROR
    case 0x88890019u:  // AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED
    case 0x88890020u:  // AUDCLNT_E_INVALID_DEVICE_PERIOD
      return true;
    default:
      return false;
  }
}

inline ExclusiveStep ClassifyExclusiveCall(int32_t hr) {
  if (hr == 0) return ExclusiveStep::kContinue;
  if (static_cast<uint32_t>(hr) == 0x8889000Au)
    return ExclusiveStep::kDeviceInUse;
  if (ExclusiveFormatRejected(hr)) return ExclusiveStep::kUnsupported;
  return ExclusiveStep::kDeviceInUse;
}

// Keeps the previous route when a probe is inconclusive. An explicit miss
// clears only that format's accept bit. No default endpoint is stereo PCM.
inline RouteCommit DecideAudioRoute(int previous_channels,
                                   uint32_t previous_accept,
                                   const RouteObservation& observed) {
  const int kept_channels = previous_channels < 1 ? 2 : previous_channels;
  const uint32_t kept_accept = previous_accept;
  auto commit_of = [&](int channels, uint32_t accept) {
    RouteCommit commit;
    commit.max_pcm_channels = channels;
    commit.accepted_passthrough = accept;
    commit.publish = channels != kept_channels || accept != kept_accept;
    return commit;
  };
  if (!observed.endpoint_present) return commit_of(2, 0);
  const bool blocked =
      observed.device_in_use ||
      observed.eac3 == ExclusiveProbe::kDeviceInUse ||
      observed.truehd == ExclusiveProbe::kDeviceInUse;
  if (blocked) return commit_of(kept_channels, kept_accept);
  uint32_t accept = kept_accept;
  auto apply = [&](ExclusiveProbe probe, uint32_t bit) {
    if (probe == ExclusiveProbe::kAccepted) accept |= bit;
    else if (probe == ExclusiveProbe::kUnsupported) accept &= ~bit;
  };
  apply(observed.eac3, RILLIGHT_CORE_AUDIO_ACCEPT_EAC3);
  apply(observed.truehd, RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD);
  const int channels = observed.mix_known
                           ? PcmChannelTarget(observed.mix_channels)
                           : kept_channels;
  return commit_of(channels, accept);
}

}  // namespace rillight_windows
