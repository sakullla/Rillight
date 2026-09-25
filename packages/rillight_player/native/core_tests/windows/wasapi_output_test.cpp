#include <Windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <thread>

using Microsoft::WRL::ComPtr;

int main() {
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) return 1;
  ComPtr<IMMDeviceEnumerator> enumerator;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                              CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) return 2;
  ComPtr<IMMDevice> device;
  if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole,
                                                &device))) return 3;
  ComPtr<IAudioClient> client;
  if (FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                              reinterpret_cast<void**>(client.GetAddressOf()))))
    return 4;
  WAVEFORMATEX format{};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = 2;
  format.nSamplesPerSec = 48000;
  format.wBitsPerSample = 16;
  format.nBlockAlign = 4;
  format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
  if (FAILED(client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                    AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                                500000, 0, &format, nullptr))) return 5;
  UINT32 capacity = 0;
  if (FAILED(client->GetBufferSize(&capacity))) return 6;
  ComPtr<IAudioRenderClient> render;
  if (FAILED(client->GetService(IID_PPV_ARGS(&render)))) return 7;
  const UINT32 count = std::min<UINT32>(capacity, 960);
  if (count == 0) return 8;
  BYTE* bytes = nullptr;
  if (FAILED(render->GetBuffer(count, &bytes))) return 9;
  auto* samples = reinterpret_cast<int16_t*>(bytes);
  for (UINT32 frame = 0; frame < count; ++frame) {
    const auto value = static_cast<int16_t>(
        std::sin(frame * 2.0 * 3.14159265358979323846 * 440.0 / 48000.0) *
        1200.0);
    samples[frame * 2] = value;
    samples[frame * 2 + 1] = value;
  }
  if (FAILED(render->ReleaseBuffer(count, 0))) return 10;
  if (FAILED(client->Start())) return 11;
  std::this_thread::sleep_for(std::chrono::milliseconds(80));
  UINT32 padding = 0;
  if (FAILED(client->GetCurrentPadding(&padding))) return 12;
  client->Stop();
  CoUninitialize();
  std::printf("WASAPI accepted %u frames; remaining padding=%u\n", count,
              padding);
  return padding < count ? 0 : 13;
}
