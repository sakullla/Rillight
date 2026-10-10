#include "../../../macos/rillight_player/Sources/rillight_player/CoreAudioOutput.h"
#include <cassert>

int main() {
  using namespace rillight_macos;
  AudioStreamBasicDescription format{};
  format.mFormatID = kAudioFormat60958AC3;
  format.mSampleRate = 48000;
  format.mChannelsPerFrame = 2;
  format.mBytesPerFrame = 4;
  format.mBitsPerChannel = 16;
  assert(IsDigitalFormat(format.mFormatID));
  assert(MatchesCarrier(format, {48000, 2}));
  assert(!MatchesCarrier(format, {192000, 2}));
  assert(!MatchesCarrier(format, {48000, 8}));
  assert(!IsDigitalFormat(kAudioFormatLinearPCM));
  format.mFormatFlags = kAudioFormatFlagIsNonInterleaved;
  assert(!MatchesCarrier(format, {48000, 2}));
  assert(DigitalAcceptedFormats(kAudioObjectUnknown) == 0);
  // Invalid kinds must not acquire a device or start a physical stream.
  CoreAudioDigital invalid(99, 48000);
  assert(invalid.failed());
  assert(invalid.DelayUs() == -1);
  invalid.Reset();
  assert(invalid.failed());
  return 0;
}
