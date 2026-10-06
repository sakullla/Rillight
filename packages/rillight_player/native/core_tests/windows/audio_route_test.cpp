#include "../../../windows/audio_route.h"

#include <audioclient.h>

#include <cassert>
#include <cstdint>

namespace {

void expect_kept(const rillight_windows::RouteCommit& commit, int channels,
                 uint32_t accept) {
  assert(!commit.publish);
  assert(commit.max_pcm_channels == channels);
  assert(commit.accepted_passthrough == accept);
}

}  // namespace

int main() {
  static_assert(static_cast<uint32_t>(AUDCLNT_E_DEVICE_IN_USE) == 0x8889000Au);
  static_assert(static_cast<uint32_t>(AUDCLNT_E_UNSUPPORTED_FORMAT) ==
                0x88890008u);
  static_assert(static_cast<uint32_t>(AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED) ==
                0x8889000Eu);
  static_assert(static_cast<uint32_t>(AUDCLNT_E_INVALID_SIZE) == 0x88890009u);
  static_assert(static_cast<uint32_t>(AUDCLNT_E_BUFFER_TOO_LARGE) ==
                0x88890006u);
  static_assert(static_cast<uint32_t>(AUDCLNT_E_BUFDURATION_PERIOD_NOT_EQUAL) ==
                0x88890013u);
  static_assert(static_cast<uint32_t>(AUDCLNT_E_INCORRECT_BUFFER_SIZE) ==
                0x88890015u);
  static_assert(static_cast<uint32_t>(AUDCLNT_E_BUFFER_SIZE_ERROR) ==
                0x88890016u);
  static_assert(static_cast<uint32_t>(AUDCLNT_E_BUFFER_ERROR) == 0x88890018u);
  static_assert(static_cast<uint32_t>(AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED) ==
                0x88890019u);
  static_assert(static_cast<uint32_t>(AUDCLNT_E_INVALID_DEVICE_PERIOD) ==
                0x88890020u);
  static_assert(static_cast<uint32_t>(E_INVALIDARG) == 0x80070057u);
  static_assert(S_OK == 0);
  static_assert(S_FALSE == 1);

  using rillight_windows::ClassifyExclusiveCall;
  using rillight_windows::ExclusiveProbe;
  using rillight_windows::ExclusiveStep;
  assert(ClassifyExclusiveCall(S_OK) == ExclusiveStep::kContinue);
  assert(ClassifyExclusiveCall(static_cast<int32_t>(AUDCLNT_E_DEVICE_IN_USE)) ==
         ExclusiveStep::kDeviceInUse);
  assert(ClassifyExclusiveCall(S_FALSE) == ExclusiveStep::kUnsupported);
  assert(ClassifyExclusiveCall(
             static_cast<int32_t>(AUDCLNT_E_UNSUPPORTED_FORMAT)) ==
         ExclusiveStep::kUnsupported);
  assert(ClassifyExclusiveCall(
             static_cast<int32_t>(AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED)) ==
         ExclusiveStep::kUnsupported);
  assert(ClassifyExclusiveCall(static_cast<int32_t>(E_INVALIDARG)) ==
         ExclusiveStep::kUnsupported);
  // Not a format rejection: do not clear an accept bit for this HRESULT.
  assert(ClassifyExclusiveCall(
             static_cast<int32_t>(AUDCLNT_E_ENDPOINT_CREATE_FAILED)) ==
         ExclusiveStep::kDeviceInUse);
  assert(ClassifyExclusiveCall(
             static_cast<int32_t>(AUDCLNT_E_DEVICE_INVALIDATED)) ==
         ExclusiveStep::kDeviceInUse);

  const uint32_t both = RILLIGHT_CORE_AUDIO_ACCEPT_EAC3 |
                        RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD;
  rillight_windows::RouteObservation busy;
  busy.endpoint_present = true;
  busy.device_in_use = true;
  busy.mix_known = true;
  busy.mix_channels = 2;
  busy.eac3 = ExclusiveProbe::kUnsupported;
  busy.truehd = ExclusiveProbe::kUnsupported;
  expect_kept(rillight_windows::DecideAudioRoute(6, both, busy), 6, both);

  rillight_windows::RouteObservation one_busy;
  one_busy.endpoint_present = true;
  one_busy.mix_known = true;
  one_busy.mix_channels = 2;
  one_busy.eac3 = ExclusiveProbe::kDeviceInUse;
  one_busy.truehd = ExclusiveProbe::kUnsupported;
  expect_kept(rillight_windows::DecideAudioRoute(
                  6, RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD, one_busy),
              6, RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD);

  rillight_windows::RouteObservation truehd_only;
  truehd_only.endpoint_present = true;
  truehd_only.mix_known = true;
  truehd_only.mix_channels = 8;
  truehd_only.eac3 = ExclusiveProbe::kUnsupported;
  truehd_only.truehd = ExclusiveProbe::kAccepted;
  const auto truehd = rillight_windows::DecideAudioRoute(8, both, truehd_only);
  assert(truehd.publish);
  assert(truehd.max_pcm_channels == 8);
  assert(truehd.accepted_passthrough == RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD);

  rillight_windows::RouteObservation stereo;
  stereo.endpoint_present = true;
  stereo.mix_known = true;
  stereo.mix_channels = 2;
  stereo.eac3 = ExclusiveProbe::kUnsupported;
  stereo.truehd = ExclusiveProbe::kUnsupported;
  const auto downmix = rillight_windows::DecideAudioRoute(6, both, stereo);
  assert(downmix.publish);
  assert(downmix.max_pcm_channels == 2);
  assert(downmix.accepted_passthrough == 0);
  expect_kept(rillight_windows::DecideAudioRoute(2, 0, stereo), 2, 0);

  rillight_windows::RouteObservation six;
  six.endpoint_present = true;
  six.mix_known = true;
  six.mix_channels = 6;
  six.eac3 = ExclusiveProbe::kUnsupported;
  six.truehd = ExclusiveProbe::kUnsupported;
  const auto multichannel = rillight_windows::DecideAudioRoute(2, 0, six);
  assert(multichannel.publish);
  assert(multichannel.max_pcm_channels == 6);
  assert(multichannel.accepted_passthrough == 0);

  rillight_windows::RouteObservation mix_unread;
  mix_unread.endpoint_present = true;
  mix_unread.eac3 = ExclusiveProbe::kUnsupported;
  mix_unread.truehd = ExclusiveProbe::kAccepted;
  const auto keep_channels =
      rillight_windows::DecideAudioRoute(6, both, mix_unread);
  assert(keep_channels.publish);
  assert(keep_channels.max_pcm_channels == 6);
  assert(keep_channels.accepted_passthrough ==
         RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD);

  rillight_windows::RouteObservation gone;
  const auto unplugged = rillight_windows::DecideAudioRoute(6, both, gone);
  assert(unplugged.publish);
  assert(unplugged.max_pcm_channels == 2);
  assert(unplugged.accepted_passthrough == 0);
  expect_kept(rillight_windows::DecideAudioRoute(2, 0, gone), 2, 0);
  return 0;
}
