#include "../../../macos/rillight_player/Sources/rillight_player/CoreAudioOutput.h"
#include "../../../macos/rillight_player/Sources/rillight_player/PixelBufferOutput.h"

#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace {
std::string DeviceName() {
  AudioDeviceID device = kAudioObjectUnknown;
  UInt32 size = sizeof(device);
  AudioObjectPropertyAddress address{kAudioHardwarePropertyDefaultOutputDevice,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr,
                                 &size, &device) != noErr ||
      device == kAudioObjectUnknown) return "unavailable";
  CFStringRef name = nullptr;
  address.mSelector = kAudioObjectPropertyName;
  size = sizeof(name);
  if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &name) != noErr ||
      !name) return "unnamed";
  char buffer[256] = {};
  CFStringGetCString(name, buffer, sizeof(buffer), kCFStringEncodingUTF8);
  CFRelease(name);
  AudioBufferList* layout = nullptr;
  address.mSelector = kAudioDevicePropertyStreamConfiguration;
  address.mScope = kAudioObjectPropertyScopeOutput;
  UInt32 layout_size = 0;
  AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &layout_size);
  std::string channels = "?";
  if (layout_size > 0) {
    std::vector<uint8_t> storage(layout_size);
    layout = reinterpret_cast<AudioBufferList*>(storage.data());
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &layout_size, layout) == noErr) {
      UInt32 count = 0;
      for (UInt32 index = 0; index < layout->mNumberBuffers; ++index)
        count += layout->mBuffers[index].mNumberChannels;
      channels = std::to_string(count);
    }
  }
  return std::string(buffer) + " channels=" + channels;
}
}

int main() {
  @autoreleasepool {
    std::printf("CASE audio-device name=%s\n", DeviceName().c_str());
    rillight_macos::CoreAudioOutput output;
    std::vector<uint8_t> tone(3840);
    for (size_t index = 0; index + 1 < tone.size(); index += 4) {
      const int16_t sample = static_cast<int16_t>(((index / 4) % 48) * 200);
      tone[index] = static_cast<uint8_t>(sample);
      tone[index + 1] = static_cast<uint8_t>(sample >> 8);
      tone[index + 2] = tone[index];
      tone[index + 3] = tone[index + 1];
    }
    size_t accepted = 0;
    for (int repeat = 0; repeat < 20; ++repeat)
      accepted += output.Write(tone.data(), tone.size());
    const int64_t delay = output.DelayUs();
    std::printf("CASE coreaudio ok=%d bytes=%zu delay_us=%lld error=%s\n",
                output.error().empty() && accepted > 0, accepted,
                static_cast<long long>(delay),
                output.error().empty() ? "none" : output.error().c_str());

    constexpr int width = 1920;
    constexpr int height = 1080;
    std::vector<uint8_t> rgba(static_cast<size_t>(width) * height * 4, 180);
    RillightCoreFrame frame{};
    frame.type = RILLIGHT_CORE_VIDEO_RGBA;
    frame.width = width;
    frame.height = height;
    frame.stride = width * 4;
    frame.data = rgba.data();
    frame.data_size = static_cast<int>(rgba.size());
    frame.sar_num = frame.sar_den = 1;
    rillight_macos::PixelBufferOutput pixels;
    std::vector<int64_t> costs;
    for (int repeat = 0; repeat < 20; ++repeat) {
      const auto started = std::chrono::steady_clock::now();
      CVPixelBufferRef buffer = nullptr;
      const CVReturn created = pixels.Render(frame, width, height, &buffer);
      const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
          std::chrono::steady_clock::now() - started).count();
      if (created != kCVReturnSuccess || !buffer) {
        std::printf("CASE iosurface ok=0 cv=%d\n", created);
        return 2;
      }
      CVPixelBufferRelease(buffer);
      costs.push_back(elapsed);
    }
    const int64_t iosurface_first = costs.front();
    std::sort(costs.begin(), costs.end());
    std::printf("CASE iosurface ok=1 first_us=%lld median_us=%lld max_us=%lld budget_us=16667\n",
                static_cast<long long>(iosurface_first),
                static_cast<long long>(costs[costs.size() / 2]),
                static_cast<long long>(costs.back()));

    // Retina player view: 1920x1080 frame fitted into a 2940x1652 content
    // rect inside a 2940x1846 window. The old path is the scalar WriteBgra.
    constexpr int view_width = 2940;
    constexpr int view_height = 1846;
    std::vector<uint8_t> scalar(static_cast<size_t>(view_width) * view_height * 4);
    std::vector<int64_t> scalar_costs;
    for (int repeat = 0; repeat < 20; ++repeat) {
      const auto started = std::chrono::steady_clock::now();
      const bool wrote = rillight_macos::WriteBgra(
          frame, view_width, view_height, scalar.data(),
          static_cast<size_t>(view_width) * 4, scalar.size());
      const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
          std::chrono::steady_clock::now() - started).count();
      if (!wrote) {
        std::printf("CASE scalar-fit ok=0\n");
        return 4;
      }
      scalar_costs.push_back(elapsed);
    }
    std::sort(scalar_costs.begin(), scalar_costs.end());
    rillight_macos::PixelBufferOutput fitted;
    std::vector<int64_t> fit_costs;
    for (int repeat = 0; repeat < 20; ++repeat) {
      const auto started = std::chrono::steady_clock::now();
      CVPixelBufferRef buffer = nullptr;
      const CVReturn created = fitted.Render(frame, view_width, view_height, &buffer);
      const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
          std::chrono::steady_clock::now() - started).count();
      if (created != kCVReturnSuccess || !buffer) {
        std::printf("CASE vimage-fit ok=0 cv=%d\n", created);
        return 5;
      }
      if (repeat == 19) {
        std::printf("CASE retina-buffer %dx%d\n",
                    static_cast<int>(CVPixelBufferGetWidth(buffer)),
                    static_cast<int>(CVPixelBufferGetHeight(buffer)));
      }
      CVPixelBufferRelease(buffer);
      fit_costs.push_back(elapsed);
    }
    const int64_t fit_first = fit_costs.front();
    std::sort(fit_costs.begin(), fit_costs.end());
    std::printf("CASE scalar-fit ok=1 median_us=%lld max_us=%lld\n",
                static_cast<long long>(scalar_costs[scalar_costs.size() / 2]),
                static_cast<long long>(scalar_costs.back()));
    std::printf("CASE retina-fit ok=1 first_us=%lld median_us=%lld max_us=%lld budget_us=16667\n",
                static_cast<long long>(fit_first),
                static_cast<long long>(fit_costs[fit_costs.size() / 2]),
                static_cast<long long>(fit_costs.back()));
    return output.error().empty() && accepted > 0 ? 0 : 3;
  }
}
