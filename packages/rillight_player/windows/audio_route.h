#pragma once

#include <cstdint>

#include "../native/core/rillight_core.h"

namespace rillight_windows {

// Thrown-away exclusive probes and the live stream share one classification.
// DEVICE_IN_USE means a client still holds the endpoint; it is not evidence
// that the receiver rejected E-AC-3 or TrueHD. DEVICE_INVALIDATED and
// ENDPOINT_CREATE_FAILED mean the endpoint itself is gone.
enum class ExclusiveProbe : int {
  kUnprobed = 0,
  kAccepted = 1,
  kUnsupported = 2,
  kDeviceInUse = 3,
  kEndpointLost = 4,
};

enum class ExclusiveStep : int {
  kContinue = 0,
  kUnsupported = 1,
  kDeviceInUse = 2,
  kEndpointLost = 3,
};

enum class ExclusiveOpenAction : int {
  kPlay = 0,
  kRetry = 1,
  kRefresh = 2,
  kUsePcm = 3,
};

// One DEVICE_IN_USE is retried. Three in a row leave this format and open PCM.
inline constexpr int kExclusiveOpenAttemptLimit = 3;

struct RouteObservation {
  bool endpoint_present = false;
  bool endpoint_lost = false;
  bool mix_known = false;
  int mix_channels = 0;
  ExclusiveProbe eac3 = ExclusiveProbe::kUnprobed;
  ExclusiveProbe truehd = ExclusiveProbe::kUnprobed;
  ExclusiveProbe ac3 = ExclusiveProbe::kUnprobed;
  ExclusiveProbe dts = ExclusiveProbe::kUnprobed;
  ExclusiveProbe dtshd = ExclusiveProbe::kUnprobed;
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

inline bool ExclusiveEndpointLost(int32_t hr) {
  switch (static_cast<uint32_t>(hr)) {
    case 0x88890004u:  // AUDCLNT_E_DEVICE_INVALIDATED
    case 0x8889000Fu:  // AUDCLNT_E_ENDPOINT_CREATE_FAILED
      return true;
    default:
      return false;
  }
}

inline ExclusiveStep ClassifyExclusiveCall(int32_t hr) {
  if (hr == 0) return ExclusiveStep::kContinue;
  if (static_cast<uint32_t>(hr) == 0x8889000Au)
    return ExclusiveStep::kDeviceInUse;
  if (ExclusiveEndpointLost(hr)) return ExclusiveStep::kEndpointLost;
  if (ExclusiveFormatRejected(hr)) return ExclusiveStep::kUnsupported;
  // Only DEVICE_IN_USE keeps an accept bit. Anything else is not that hold.
  return ExclusiveStep::kUnsupported;
}

// kUnprobed and kDeviceInUse keep that format's previous bit. kUnsupported
// clears only that bit. A known mix always updates the channel count.
// endpoint_lost publishes that mix, or stereo, and drops every accept bit.
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
  if (observed.endpoint_lost) {
    const int channels = observed.mix_known
                             ? PcmChannelTarget(observed.mix_channels)
                             : 2;
    return commit_of(channels, 0);
  }
  uint32_t accept = kept_accept;
  auto apply = [&](ExclusiveProbe probe, uint32_t bit) {
    if (probe == ExclusiveProbe::kAccepted) accept |= bit;
    else if (probe == ExclusiveProbe::kUnsupported ||
             probe == ExclusiveProbe::kEndpointLost) {
      accept &= ~bit;
    }
  };
  apply(observed.eac3, RILLIGHT_CORE_AUDIO_ACCEPT_EAC3);
  apply(observed.truehd, RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD);
  apply(observed.ac3, RILLIGHT_CORE_AUDIO_ACCEPT_AC3);
  apply(observed.dts, RILLIGHT_CORE_AUDIO_ACCEPT_DTS);
  apply(observed.dtshd, RILLIGHT_CORE_AUDIO_ACCEPT_DTSHD);
  const int channels = observed.mix_known
                           ? PcmChannelTarget(observed.mix_channels)
                           : kept_channels;
  return commit_of(channels, accept);
}

// A second probe that is still lost is not a device shared mode can open.
// Keep endpoint_lost so the caller waits for a new default-device generation
// instead of Initialize on this IMMDevice. A live probe is unchanged.
inline RouteObservation RouteAfterEndpointLoss(const RouteObservation& refreshed) {
  if (!refreshed.endpoint_present) return {};
  return refreshed;
}

// Live GetCurrentPadding / GetBuffer / ReleaseBuffer and shared Initialize.
// DEVICE_IN_USE and endpoint loss stay in the audio thread. Anything else
// is a real failure and may leave the thread.
enum class ClientFault : int {
  kNone = 0,
  kBusy = 1,
  kLost = 2,
  kFatal = 3,
};

enum class SharedInitResult : int {
  kReady = 0,
  kRetry = 1,
  kWaitForGeneration = 2,
  kFatal = 3,
};

inline ClientFault ClassifyClientFault(int32_t hr) {
  if (hr >= 0) return ClientFault::kNone;
  if (static_cast<uint32_t>(hr) == 0x8889000Au) return ClientFault::kBusy;
  if (ExclusiveEndpointLost(hr)) return ClientFault::kLost;
  return ClientFault::kFatal;
}

inline bool AudioThreadContinues(ClientFault fault) {
  return fault != ClientFault::kFatal;
}

// endpoint_lost is not an openable endpoint, even if a mix format was seen.
inline bool SharedInitializeAllowed(const RouteObservation& observed) {
  return observed.endpoint_present && !observed.endpoint_lost;
}

inline SharedInitResult ClassifySharedInit(int32_t hr) {
  switch (ClassifyClientFault(hr)) {
    case ClientFault::kNone:
      return SharedInitResult::kReady;
    case ClientFault::kBusy:
      return SharedInitResult::kRetry;
    case ClientFault::kLost:
      return SharedInitResult::kWaitForGeneration;
    case ClientFault::kFatal:
    default:
      return SharedInitResult::kFatal;
  }
}

inline ExclusiveOpenAction DecideExclusiveOpen(ExclusiveProbe opened,
                                               int failures_before) {
  if (opened == ExclusiveProbe::kAccepted) return ExclusiveOpenAction::kPlay;
  if (opened == ExclusiveProbe::kUnsupported) return ExclusiveOpenAction::kUsePcm;
  if (opened == ExclusiveProbe::kEndpointLost)
    return ExclusiveOpenAction::kRefresh;
  const int seen = (failures_before < 0 ? 0 : failures_before) + 1;
  if (seen >= kExclusiveOpenAttemptLimit) return ExclusiveOpenAction::kUsePcm;
  return ExclusiveOpenAction::kRetry;
}

}  // namespace rillight_windows
