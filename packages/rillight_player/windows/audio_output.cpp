#include "audio_output.h"

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <Windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <cwchar>
#include <stdexcept>

#include "audio_schedule.h"

namespace {
using Microsoft::WRL::ComPtr;

void Check(HRESULT result, const char* message) {
  if (FAILED(result)) throw std::runtime_error(message);
}

bool Active(const RillightCoreSnapshot& value) {
  return value.state == RILLIGHT_CORE_PLAYING ||
         value.state == RILLIGHT_CORE_BUFFERING ||
         value.state == RILLIGHT_CORE_RECOVERING;
}
}  // namespace

AudioOutput::AudioOutput(RillightCore* core, std::shared_ptr<CoreApi> api)
    : core_(core), api_(std::move(api)) {}

AudioOutput::~AudioOutput() { Stop(); }

void AudioOutput::Start() { worker_ = std::thread([this] { Run(); }); }

void AudioOutput::Stop() {
  stopped_ = true;
  if (worker_.joinable()) worker_.join();
}

bool AudioOutput::Empty() const {
  return !pending_ && device_padding_ == 0;
}

std::string AudioOutput::error() const {
  std::lock_guard lock(mutex_);
  return error_;
}

void AudioOutput::Run() {
  const HRESULT apartment = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(apartment)) {
    {
      std::lock_guard lock(mutex_);
      error_ = "WASAPI COM initialization failed";
    }
    DrainUnavailableAudio();
    return;
  }
#if defined(_DEBUG)
  // Exercise the missing-device path without changing the user's audio setup.
  if (GetEnvironmentVariableW(L"RILLIGHT_TEST_NO_AUDIO", nullptr, 0) > 0) {
    {
      std::lock_guard lock(mutex_);
      error_ = "WASAPI test endpoint unavailable";
    }
    CoUninitialize();
    DrainUnavailableAudio();
    return;
  }
#endif
  RillightCoreFrame* pending = nullptr;
  bool audio_failed = false;
  try {
#if defined(_DEBUG)
    wchar_t delay[16]{};
    if (GetEnvironmentVariableW(L"RILLIGHT_TEST_AUDIO_INIT_DELAY_MS", delay,
                                static_cast<DWORD>(sizeof(delay) /
                                                   sizeof(delay[0]))) > 0) {
      const int milliseconds = static_cast<int>(
          std::clamp(std::wcstol(delay, nullptr, 10), 0L, 2000L));
      std::this_thread::sleep_for(std::chrono::milliseconds(milliseconds));
    }
#endif
    ComPtr<IMMDeviceEnumerator> enumerator;
    Check(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                           IID_PPV_ARGS(&enumerator)),
          "WASAPI device enumerator unavailable");
    ComPtr<IMMDevice> device;
    Check(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device),
          "WASAPI default output unavailable");
    ComPtr<IAudioClient> client;
    Check(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                           reinterpret_cast<void**>(client.GetAddressOf())),
          "WASAPI client unavailable");
    WAVEFORMATEX format{};
    format.wFormatTag = WAVE_FORMAT_PCM;
    format.nChannels = 2;
    format.nSamplesPerSec = 48000;
    format.wBitsPerSample = 16;
    format.nBlockAlign = 4;
    format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
    Check(client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                             AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                 AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                             500000, 0, &format, nullptr),
          "WASAPI 48 kHz stereo output initialization failed");
    UINT32 capacity = 0;
    Check(client->GetBufferSize(&capacity), "WASAPI buffer size unavailable");
    REFERENCE_TIME stream_latency_ticks = 0;
    if (FAILED(client->GetStreamLatency(&stream_latency_ticks)))
      stream_latency_ticks = 0;
    const int64_t stream_latency_us =
        std::max<int64_t>(0, stream_latency_ticks / 10);
    ComPtr<IAudioRenderClient> render;
    Check(client->GetService(IID_PPV_ARGS(&render)),
          "WASAPI render service unavailable");

    uint64_t session = 0;
    uint64_t timeline = 0;
    int offset = 0;
    int64_t submitted_media_end = -1;
    bool handed_off_audio_clock = false;
    bool audio_clock_started = false;
    rillight_windows::AudioHandoffPolicy handoff_policy;
    bool running = false;
    while (!stopped_) {
      RillightCoreSnapshot state{};
      state.struct_size = sizeof(state);
      if (api_->snapshot(core_, &state) != 0) break;
      if (state.session_id != session || state.timeline_version != timeline) {
        if (running) Check(client->Stop(), "WASAPI stop failed");
        running = false;
        Check(client->Reset(), "WASAPI timeline reset failed");
        if (pending) api_->release_frame(pending);
        pending = nullptr;
        pending_ = false;
        device_padding_ = 0;
        offset = 0;
        submitted_media_end = -1;
        handed_off_audio_clock = false;
        audio_clock_started = false;
        handoff_policy.Reset();
        session = state.session_id;
        timeline = state.timeline_version;
      }
      if (!Active(state)) {
        if (running) Check(client->Stop(), "WASAPI pause failed");
        running = false;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        continue;
      }
      UINT32 padding = 0;
      Check(client->GetCurrentPadding(&padding), "WASAPI padding unavailable");
      device_padding_ = padding;
      if (capacity > padding && !pending) {
        pending = api_->take_frame(core_, RILLIGHT_CORE_AUDIO_S16);
        pending_ = pending != nullptr;
        offset = 0;
      }
      bool waiting_future_audio = false;
      if (pending) {
        if (pending->session_id != session ||
            pending->timeline_version != timeline || !pending->data ||
            pending->sample_rate != 48000 || pending->channels != 2 ||
            pending->sample_count < 0 ||
            static_cast<int64_t>(pending->data_size) <
                static_cast<int64_t>(pending->sample_count) * 4) {
          api_->release_frame(pending);
          pending = nullptr;
          pending_ = false;
        } else {
          if (!audio_clock_started && pending->pts_us >= 0) {
            if (pending->pts_us > state.position_us + 50000) {
              std::this_thread::sleep_for(std::chrono::milliseconds(4));
              continue;
            }
            offset = std::max(offset, rillight_windows::StartupSampleOffset(
                *pending, state.position_us, state.playback_speed));
          }
          if (audio_clock_started && pending->pts_us >= 0 &&
              pending->pts_us > state.position_us + 50000) {
            waiting_future_audio = true;
          }
          if (!waiting_future_audio) {
            if (handed_off_audio_clock) {
              handed_off_audio_clock = false;
              submitted_media_end = -1;
            }
            if (offset >= pending->sample_count) {
              api_->release_frame(pending);
              pending = nullptr;
              pending_ = false;
            } else {
              const UINT32 count = std::min<UINT32>(
                  capacity - padding, pending->sample_count - offset);
              if (count > 0) {
                BYTE* output = nullptr;
                Check(render->GetBuffer(count, &output),
                      "WASAPI buffer unavailable");
                std::memcpy(output,
                            pending->data + static_cast<size_t>(offset) * 4,
                            static_cast<size_t>(count) * 4);
                Check(render->ReleaseBuffer(count, 0),
                      "WASAPI buffer commit failed");
                offset += count;
                device_padding_ = padding + count;
                if (pending->pts_us >= 0) {
                  submitted_media_end = pending->pts_us + static_cast<int64_t>(
                      offset * 1000000.0 / 48000.0 * state.playback_speed);
                }
              }
              if (offset >= pending->sample_count) {
                api_->release_frame(pending);
                pending = nullptr;
                pending_ = false;
              }
            }
          }
        }
      }
      if (!running && device_padding_ > 0) {
        Check(client->Start(), "WASAPI playback start failed");
        running = true;
      }
      if (submitted_media_end >= 0) {
        if (handoff_policy.ShouldHandoff(state, pending != nullptr,
                                         waiting_future_audio,
                                         device_padding_, audio_clock_started,
                                         std::chrono::steady_clock::now()) &&
            api_->report_audio_unavailable(core_, session, timeline) == 0) {
          handed_off_audio_clock = true;
          audio_clock_started = false;
          submitted_media_end = -1;
          handoff_policy.Reset();
        } else if (!handed_off_audio_clock) {
          const int64_t queued_media_us = static_cast<int64_t>(
              device_padding_.load() * 1000000.0 / 48000.0 *
              state.playback_speed) + static_cast<int64_t>(
                  stream_latency_us * state.playback_speed);
          if (api_->report_audio_played(core_, session, timeline,
                                        submitted_media_end,
                                        queued_media_us) == 0) {
            audio_clock_started = true;
          } else if (!audio_clock_started) {
            if (running) Check(client->Stop(), "WASAPI realign stop failed");
            running = false;
            Check(client->Reset(), "WASAPI realign reset failed");
            device_padding_ = 0;
            submitted_media_end = -1;
          }
        }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(4));
    }
    if (running) client->Stop();
  } catch (const std::exception& exception) {
    std::lock_guard lock(mutex_);
    error_ = exception.what();
    audio_failed = true;
  }
  if (pending) api_->release_frame(pending);
  pending_ = false;
  device_padding_ = 0;
  CoUninitialize();
  if (audio_failed && !stopped_) DrainUnavailableAudio();
}

void AudioOutput::DrainUnavailableAudio() {
  uint64_t session = 0;
  uint64_t timeline = 0;
  while (!stopped_) {
    RillightCoreSnapshot state{};
    state.struct_size = sizeof(state);
    if (api_->snapshot(core_, &state) != 0) return;
    if (state.session_id != session || state.timeline_version != timeline) {
      session = state.session_id;
      timeline = state.timeline_version;
      if (session != 0) {
        api_->report_audio_unavailable(core_, session, timeline);
      }
    }
    while (auto* frame = api_->take_frame(core_, RILLIGHT_CORE_AUDIO_S16)) {
      api_->release_frame(frame);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
}
