#include "../../../windows/audio_route.h"
#include "../../../windows/audio_transport.h"
#include "../../core/iec61937_pack.h"

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
  using namespace rillight_windows;
  for (int kind : {RILLIGHT_CORE_PASSTHROUGH_AC3, RILLIGHT_CORE_PASSTHROUGH_EAC3,
                   RILLIGHT_CORE_PASSTHROUGH_DTS, RILLIGHT_CORE_PASSTHROUGH_DTSHD,
                   RILLIGHT_CORE_PASSTHROUGH_TRUEHD}) {
    const auto bit = rillight_passthrough_accept_bit(kind);
    for (int channels : {2, 6, 8}) {
      const auto accepted = rillight_audio_contract(channels, kind, 8, bit, 0, 1);
      assert(accepted.passthrough && accepted.channels == channels && !accepted.atmos);
      assert(!rillight_audio_contract(channels, kind, 8, 0, 1, 1).passthrough);
      assert(!rillight_audio_contract(channels, kind, 8, bit, 1, 1.25).passthrough);
    }
    RouteObservation observed; observed.endpoint_present = true;
    observed.ac3 = observed.eac3 = observed.dts = observed.dtshd = observed.truehd = ExclusiveProbe::kAccepted;
    assert((DecideAudioRoute(2, 0, observed).accepted_passthrough & bit) != 0);
    observed.endpoint_lost = true;
    assert(DecideAudioRoute(2, bit, observed).accepted_passthrough == 0);
  }
  assert(!rillight_audio_contract(2, RILLIGHT_CORE_PASSTHROUGH_EAC3, 8,
      RILLIGHT_CORE_AUDIO_ACCEPT_EAC3, 1, 1).atmos);
  assert(EncodedTransport(RILLIGHT_CORE_PASSTHROUGH_EAC3, 44100).rate == 176400);
  assert(EncodedTransport(RILLIGHT_CORE_PASSTHROUGH_AC3, 32000).rate == 32000);
  assert(EncodedTransport(RILLIGHT_CORE_PASSTHROUGH_DTS, 48000, 1024).period_bytes == 4096);
  assert(EncodedTransport(RILLIGHT_CORE_PASSTHROUGH_DTSHD, 48000, 512).period_bytes == 32768);
  assert(EncodedTransport(RILLIGHT_CORE_PASSTHROUGH_DTSHD, 44100, 512).period_bytes == 0);
  assert(EncodedTransport(RILLIGHT_CORE_PASSTHROUGH_DTS, 48000, 123).period_bytes == 0);
  RillightIec61937Mux mux;
  std::vector<uint8_t> packet(128), burst;
  packet[0] = 0x0b; packet[1] = 0x77; packet[5] = 8 << 3;
  assert(mux.push_ac3(packet.data(), 128, &burst) == 1);
  assert(burst.size() == 6144 && burst[4] == 1 && burst[6] == 0 && burst[7] == 4);
  assert(mux.push_ac3(packet.data(), 3, &burst) == -1);
  for (int samples : {512, 1024, 2048}) {
    packet.assign(128, 0);
    packet[0] = 0x7f; packet[1] = 0xfe; packet[2] = 0x80; packet[3] = 1;
    const int blocks = samples / 32 - 1;
    packet[4] = static_cast<uint8_t>(blocks >> 6); packet[5] = static_cast<uint8_t>((blocks & 63) << 2);
    packet[6] = 7; packet[7] = 0xf0; packet[8] = 13 << 2;
    assert(mux.push_dts(packet.data(), 128, false, &burst) == 1);
    assert(burst.size() == static_cast<size_t>(samples * 4));
    assert(burst[6] == 0 && burst[7] == 4);
    const auto be = burst;
    for (size_t i = 0; i < packet.size(); i += 2) std::swap(packet[i], packet[i + 1]);
    assert(mux.push_dts(packet.data(), 128, false, &burst) == 1 && burst == be);
    for (size_t i = 0; i < packet.size(); i += 2) std::swap(packet[i], packet[i + 1]);
    packet.resize(256);
    assert(mux.push_dts(packet.data(), 256, false, &burst) == -1);
    if (samples <= 1024) {
      assert(mux.push_dts(packet.data(), 256, true, &burst) == 1);
      assert(burst[4] == 0x11 && burst.size() == static_cast<size_t>(samples * 64));
    }
  }

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
  static_assert(static_cast<uint32_t>(AUDCLNT_E_DEVICE_INVALIDATED) ==
                0x88890004u);
  static_assert(static_cast<uint32_t>(AUDCLNT_E_ENDPOINT_CREATE_FAILED) ==
                0x8889000Fu);
  // Endpoint loss is not DEVICE_IN_USE and must not keep the old route.
  assert(ClassifyExclusiveCall(
             static_cast<int32_t>(AUDCLNT_E_ENDPOINT_CREATE_FAILED)) ==
         ExclusiveStep::kEndpointLost);
  assert(ClassifyExclusiveCall(
             static_cast<int32_t>(AUDCLNT_E_DEVICE_INVALIDATED)) ==
         ExclusiveStep::kEndpointLost);
  // Only DEVICE_IN_USE keeps an accept bit. E_FAIL does not.
  assert(ClassifyExclusiveCall(static_cast<int32_t>(0x80004005)) ==
         ExclusiveStep::kUnsupported);

  const uint32_t both = RILLIGHT_CORE_AUDIO_ACCEPT_EAC3 |
                        RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD;
  rillight_windows::RouteObservation busy_stereo;
  busy_stereo.endpoint_present = true;
  busy_stereo.mix_known = true;
  busy_stereo.mix_channels = 2;
  busy_stereo.eac3 = ExclusiveProbe::kDeviceInUse;
  busy_stereo.truehd = ExclusiveProbe::kDeviceInUse;
  const auto busy = rillight_windows::DecideAudioRoute(6, both, busy_stereo);
  assert(busy.publish);
  assert(busy.max_pcm_channels == 2);
  assert(busy.accepted_passthrough == both);

  rillight_windows::RouteObservation one_busy;
  one_busy.endpoint_present = true;
  one_busy.mix_known = true;
  one_busy.mix_channels = 2;
  one_busy.eac3 = ExclusiveProbe::kDeviceInUse;
  one_busy.truehd = ExclusiveProbe::kUnsupported;
  const auto dropped = rillight_windows::DecideAudioRoute(
      6, RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD, one_busy);
  assert(dropped.publish);
  assert(dropped.max_pcm_channels == 2);
  assert(dropped.accepted_passthrough == 0);

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

  rillight_windows::RouteObservation rejected;
  rejected.endpoint_present = true;
  rejected.eac3 = ExclusiveProbe::kUnsupported;
  rejected.truehd = ExclusiveProbe::kUnsupported;
  const auto cleared = rillight_windows::DecideAudioRoute(6, both, rejected);
  assert(cleared.publish);
  assert(cleared.max_pcm_channels == 6);
  assert(cleared.accepted_passthrough == 0);

  rillight_windows::RouteObservation unread_probe;
  unread_probe.endpoint_present = true;
  unread_probe.mix_known = true;
  unread_probe.mix_channels = 6;
  unread_probe.truehd = ExclusiveProbe::kUnsupported;
  const auto unprobed = rillight_windows::DecideAudioRoute(6, both, unread_probe);
  assert(unprobed.publish);
  assert(unprobed.max_pcm_channels == 6);
  assert(unprobed.accepted_passthrough == RILLIGHT_CORE_AUDIO_ACCEPT_EAC3);

  rillight_windows::RouteObservation invalidated;
  invalidated.endpoint_present = true;
  invalidated.endpoint_lost = true;
  invalidated.mix_known = true;
  invalidated.mix_channels = 2;
  invalidated.eac3 = ExclusiveProbe::kAccepted;
  invalidated.truehd = ExclusiveProbe::kDeviceInUse;
  const auto lost = rillight_windows::DecideAudioRoute(6, both, invalidated);
  assert(lost.publish);
  assert(lost.max_pcm_channels == 2);
  assert(lost.accepted_passthrough == 0);

  rillight_windows::RouteObservation lost_unread;
  lost_unread.endpoint_present = true;
  lost_unread.endpoint_lost = true;
  const auto lost_stereo =
      rillight_windows::DecideAudioRoute(6, both, lost_unread);
  assert(lost_stereo.publish);
  assert(lost_stereo.max_pcm_channels == 2);
  assert(lost_stereo.accepted_passthrough == 0);

  rillight_windows::RouteObservation still_lost;
  still_lost.endpoint_present = true;
  still_lost.endpoint_lost = true;
  still_lost.mix_known = true;
  still_lost.mix_channels = 2;
  still_lost.truehd = ExclusiveProbe::kAccepted;
  const auto after_loss = rillight_windows::RouteAfterEndpointLoss(still_lost);
  // A second loss stays lost. Do not rewrite it into a device Initialize
  // can open; the snapshot is stereo with passthrough cleared.
  assert(after_loss.endpoint_present);
  assert(after_loss.endpoint_lost);
  assert(after_loss.mix_channels == 2);
  assert(after_loss.truehd == ExclusiveProbe::kAccepted);
  assert(!rillight_windows::SharedInitializeAllowed(after_loss));
  const auto published =
      rillight_windows::DecideAudioRoute(6, both, after_loss);
  assert(published.publish);
  assert(published.max_pcm_channels == 2);
  assert(published.accepted_passthrough == 0);
  assert(rillight_windows::ClassifyClientFault(
             static_cast<int32_t>(AUDCLNT_E_DEVICE_INVALIDATED)) ==
         rillight_windows::ClientFault::kLost);
  assert(rillight_windows::ClassifyClientFault(
             static_cast<int32_t>(AUDCLNT_E_ENDPOINT_CREATE_FAILED)) ==
         rillight_windows::ClientFault::kLost);
  assert(rillight_windows::ClassifyClientFault(
             static_cast<int32_t>(AUDCLNT_E_DEVICE_IN_USE)) ==
         rillight_windows::ClientFault::kBusy);
  assert(rillight_windows::ClassifyClientFault(S_OK) ==
         rillight_windows::ClientFault::kNone);
  assert(rillight_windows::ClassifyClientFault(static_cast<int32_t>(0x80004005)) ==
         rillight_windows::ClientFault::kFatal);
  assert(rillight_windows::AudioThreadContinues(
      rillight_windows::ClientFault::kLost));
  assert(rillight_windows::AudioThreadContinues(
      rillight_windows::ClientFault::kBusy));
  assert(!rillight_windows::AudioThreadContinues(
      rillight_windows::ClientFault::kFatal));
  assert(rillight_windows::ClassifySharedInit(
             static_cast<int32_t>(AUDCLNT_E_DEVICE_INVALIDATED)) ==
         rillight_windows::SharedInitResult::kWaitForGeneration);
  assert(rillight_windows::ClassifySharedInit(
             static_cast<int32_t>(AUDCLNT_E_ENDPOINT_CREATE_FAILED)) ==
         rillight_windows::SharedInitResult::kWaitForGeneration);
  assert(rillight_windows::ClassifySharedInit(
             static_cast<int32_t>(AUDCLNT_E_DEVICE_IN_USE)) ==
         rillight_windows::SharedInitResult::kRetry);
  assert(rillight_windows::ClassifySharedInit(S_OK) ==
         rillight_windows::SharedInitResult::kReady);
  assert(rillight_windows::ClassifySharedInit(static_cast<int32_t>(0x80004005)) ==
         rillight_windows::SharedInitResult::kFatal);

  rillight_windows::RouteObservation healthy;
  healthy.endpoint_present = true;
  healthy.mix_known = true;
  healthy.mix_channels = 6;
  healthy.truehd = ExclusiveProbe::kAccepted;
  assert(rillight_windows::RouteAfterEndpointLoss(healthy).truehd ==
         ExclusiveProbe::kAccepted);
  assert(rillight_windows::SharedInitializeAllowed(
      rillight_windows::RouteAfterEndpointLoss(healthy)));
  assert(!rillight_windows::RouteAfterEndpointLoss({}).endpoint_present);
  assert(!rillight_windows::SharedInitializeAllowed({}));

  using rillight_windows::DecideExclusiveOpen;
  using rillight_windows::ExclusiveOpenAction;
  assert(DecideExclusiveOpen(ExclusiveProbe::kAccepted, 4) ==
         ExclusiveOpenAction::kPlay);
  assert(DecideExclusiveOpen(ExclusiveProbe::kUnsupported, 0) ==
         ExclusiveOpenAction::kUsePcm);
  assert(DecideExclusiveOpen(ExclusiveProbe::kEndpointLost, 0) ==
         ExclusiveOpenAction::kRefresh);
  assert(DecideExclusiveOpen(ExclusiveProbe::kDeviceInUse, 0) ==
         ExclusiveOpenAction::kRetry);
  assert(DecideExclusiveOpen(ExclusiveProbe::kDeviceInUse, 1) ==
         ExclusiveOpenAction::kRetry);
  assert(DecideExclusiveOpen(ExclusiveProbe::kDeviceInUse, 2) ==
         ExclusiveOpenAction::kUsePcm);
  assert(DecideExclusiveOpen(ExclusiveProbe::kUnprobed, 2) ==
         ExclusiveOpenAction::kUsePcm);
  return 0;
}
