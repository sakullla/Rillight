#include "audio_output.h"

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <Windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <cwchar>
#include <stdexcept>
#include <vector>

#include "../native/core/iec61937_pack.h"
#include "audio_route.h"
#include "audio_schedule.h"

namespace {
using Microsoft::WRL::ComPtr;

const GUID kIecEac3 = {0x0000000a, 0x0cea, 0x0010,
                       {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
const GUID kIecTrueHd = {0x0000000c, 0x0cea, 0x0010,
                         {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};

struct IecWave {
  WAVEFORMATEXTENSIBLE ext;
  DWORD encoded_rate;
  DWORD encoded_channels;
  DWORD average_bytes;
};

void Check(HRESULT result, const char* message) {
  if (FAILED(result)) throw std::runtime_error(message);
}

bool Active(const RillightCoreSnapshot& value) {
  return value.state == RILLIGHT_CORE_PLAYING ||
         value.state == RILLIGHT_CORE_BUFFERING ||
         value.state == RILLIGHT_CORE_RECOVERING;
}

IecWave MakeIecFormat(bool truehd) {
  IecWave format{};
  const int channels = truehd ? 8 : 2;
  const int rate = 192000;
  format.ext.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
  format.ext.Format.nChannels = static_cast<WORD>(channels);
  format.ext.Format.nSamplesPerSec = rate;
  format.ext.Format.wBitsPerSample = 16;
  format.ext.Format.nBlockAlign = static_cast<WORD>(channels * 2);
  format.ext.Format.nAvgBytesPerSec = rate * format.ext.Format.nBlockAlign;
  format.ext.Format.cbSize =
      static_cast<WORD>(sizeof(IecWave) - sizeof(WAVEFORMATEX));
  format.ext.Samples.wValidBitsPerSample = 16;
  format.ext.dwChannelMask = truehd ? 0x63F : 0x3;
  format.ext.SubFormat = truehd ? kIecTrueHd : kIecEac3;
  format.encoded_rate = 48000;
  format.encoded_channels = static_cast<DWORD>(channels);
  format.average_bytes = format.ext.Format.nAvgBytesPerSec;
  return format;
}

static_assert(static_cast<uint32_t>(AUDCLNT_E_DEVICE_IN_USE) == 0x8889000Au);
static_assert(static_cast<uint32_t>(AUDCLNT_E_UNSUPPORTED_FORMAT) ==
              0x88890008u);
static_assert(static_cast<uint32_t>(AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED) ==
              0x8889000Eu);
static_assert(static_cast<uint32_t>(AUDCLNT_E_DEVICE_INVALIDATED) ==
              0x88890004u);
static_assert(static_cast<uint32_t>(AUDCLNT_E_ENDPOINT_CREATE_FAILED) ==
              0x8889000Fu);
static_assert(static_cast<uint32_t>(E_INVALIDARG) == 0x80070057u);
static_assert(S_OK == 0);
static_assert(S_FALSE == 1);

rillight_windows::ExclusiveProbe ProbeFromStep(
    rillight_windows::ExclusiveStep step) {
  switch (step) {
    case rillight_windows::ExclusiveStep::kUnsupported:
      return rillight_windows::ExclusiveProbe::kUnsupported;
    case rillight_windows::ExclusiveStep::kEndpointLost:
      return rillight_windows::ExclusiveProbe::kEndpointLost;
    case rillight_windows::ExclusiveStep::kDeviceInUse:
      return rillight_windows::ExclusiveProbe::kDeviceInUse;
    case rillight_windows::ExclusiveStep::kContinue:
      return rillight_windows::ExclusiveProbe::kAccepted;
  }
  return rillight_windows::ExclusiveProbe::kDeviceInUse;
}

rillight_windows::ExclusiveProbe FailedProbe(HRESULT hr) {
  return ProbeFromStep(rillight_windows::ClassifyExclusiveCall(hr));
}

rillight_windows::ExclusiveProbe ProbeExclusive(IMMDevice* device,
                                                bool truehd) {
  ComPtr<IAudioClient> client;
  const HRESULT activated = device->Activate(
      __uuidof(IAudioClient), CLSCTX_ALL, nullptr,
      reinterpret_cast<void**>(client.GetAddressOf()));
  const auto activation = rillight_windows::ClassifyExclusiveCall(activated);
  if (activation != rillight_windows::ExclusiveStep::kContinue)
    return ProbeFromStep(activation);
  const IecWave format = MakeIecFormat(truehd);
  const HRESULT supported = client->IsFormatSupported(
      AUDCLNT_SHAREMODE_EXCLUSIVE,
      reinterpret_cast<const WAVEFORMATEX*>(&format), nullptr);
  const auto support = rillight_windows::ClassifyExclusiveCall(supported);
  if (support != rillight_windows::ExclusiveStep::kContinue)
    return ProbeFromStep(support);
  HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (!event) return rillight_windows::ExclusiveProbe::kUnsupported;
  const REFERENCE_TIME period = truehd ? 200000 : 320000;
  const HRESULT started = client->Initialize(
      AUDCLNT_SHAREMODE_EXCLUSIVE, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, period,
      period, reinterpret_cast<const WAVEFORMATEX*>(&format), nullptr);
  const auto init = rillight_windows::ClassifyExclusiveCall(started);
  rillight_windows::ExclusiveProbe verdict =
      rillight_windows::ExclusiveProbe::kUnsupported;
  if (init != rillight_windows::ExclusiveStep::kContinue) {
    verdict = ProbeFromStep(init);
  } else {
    UINT32 frames = 0;
    const HRESULT event_hr = client->SetEventHandle(event);
    const HRESULT size_hr =
        SUCCEEDED(event_hr) ? client->GetBufferSize(&frames) : S_OK;
    if (FAILED(event_hr)) {
      verdict = FailedProbe(event_hr);
    } else if (FAILED(size_hr)) {
      verdict = FailedProbe(size_hr);
    } else {
      const int expected = truehd ? RillightIec61937Mux::kTrueHdPeriod
                                  : RillightIec61937Mux::kEac3Period;
      verdict = static_cast<int>(frames) * format.ext.Format.nBlockAlign ==
                        expected
                    ? rillight_windows::ExclusiveProbe::kAccepted
                    : rillight_windows::ExclusiveProbe::kUnsupported;
    }
    client->Stop();
  }
  CloseHandle(event);
  return verdict;
}

rillight_windows::RouteObservation ProbeOpenDevice(IMMDevice* device) {
  rillight_windows::RouteObservation result;
  result.endpoint_present = true;
  ComPtr<IAudioClient> client;
  const HRESULT activated = device->Activate(
      __uuidof(IAudioClient), CLSCTX_ALL, nullptr,
      reinterpret_cast<void**>(client.GetAddressOf()));
  const auto activation = rillight_windows::ClassifyExclusiveCall(activated);
  if (activation == rillight_windows::ExclusiveStep::kEndpointLost) {
    result.endpoint_lost = true;
    return result;
  }
  if (activation == rillight_windows::ExclusiveStep::kDeviceInUse) return result;
  if (activation != rillight_windows::ExclusiveStep::kContinue) {
    result.eac3 = rillight_windows::ExclusiveProbe::kUnsupported;
    result.truehd = rillight_windows::ExclusiveProbe::kUnsupported;
    return result;
  }
  WAVEFORMATEX* mix = nullptr;
  if (SUCCEEDED(client->GetMixFormat(&mix)) && mix) {
    if (mix->nChannels > 0) {
      result.mix_known = true;
      result.mix_channels = mix->nChannels;
    }
    CoTaskMemFree(mix);
  }
  client.Reset();
  result.eac3 = ProbeExclusive(device, false);
  result.truehd = ProbeExclusive(device, true);
  if (result.eac3 == rillight_windows::ExclusiveProbe::kDeviceInUse ||
      result.truehd == rillight_windows::ExclusiveProbe::kDeviceInUse) {
    // The previous throwaway client can still look busy for a moment.
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    if (result.eac3 == rillight_windows::ExclusiveProbe::kDeviceInUse)
      result.eac3 = ProbeExclusive(device, false);
    if (result.truehd == rillight_windows::ExclusiveProbe::kDeviceInUse)
      result.truehd = ProbeExclusive(device, true);
  }
  if (result.eac3 == rillight_windows::ExclusiveProbe::kEndpointLost ||
      result.truehd == rillight_windows::ExclusiveProbe::kEndpointLost) {
    result.endpoint_lost = true;
  }
  return result;
}

// Refreshes the default endpoint once after DEVICE_INVALIDATED or
// ENDPOINT_CREATE_FAILED. A second loss is published as PCM, not the old route.
rillight_windows::RouteObservation ProbeDefaultRoute(
    IMMDeviceEnumerator* enumerator, ComPtr<IMMDevice>* device) {
  ComPtr<IMMDevice> current;
  if (!enumerator ||
      FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole,
                                                 &current))) {
    return {};
  }
  auto observed = ProbeOpenDevice(current.Get());
  if (observed.endpoint_lost) {
    ComPtr<IMMDevice> refreshed;
    if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole,
                                                   &refreshed))) {
      return {};
    }
    current = refreshed;
    observed = rillight_windows::RouteAfterEndpointLoss(
        ProbeOpenDevice(current.Get()));
  }
  if (device) *device = current;
  return observed;
}

rillight_windows::RouteObservation ProbeDevice() {
  ComPtr<IMMDeviceEnumerator> enumerator;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                              IID_PPV_ARGS(&enumerator)))) {
    return {};
  }
  ComPtr<IMMDevice> device;
  return ProbeDefaultRoute(enumerator.Get(), &device);
}

class OutputDeviceEvents : public IMMNotificationClient {
 public:
  explicit OutputDeviceEvents(std::atomic<uint32_t>* generation)
      : generation_(generation) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override {
    if (!object) return E_POINTER;
    if (riid == __uuidof(IUnknown) || riid == __uuidof(IMMNotificationClient)) {
      *object = static_cast<IMMNotificationClient*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(InterlockedIncrement(&refs_));
  }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG left = static_cast<ULONG>(InterlockedDecrement(&refs_));
    if (left == 0) delete this;
    return left;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override {
    Bump();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override {
    Bump();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role,
                                                   LPCWSTR) override {
    if (flow == eRender && (role == eConsole || role == eMultimedia)) Bump();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR,
                                                   const PROPERTYKEY) override {
    return S_OK;
  }

 private:
  void Bump() {
    if (generation_) generation_->fetch_add(1);
  }
  std::atomic<uint32_t>* generation_ = nullptr;
  LONG refs_ = 1;
};

struct NotificationRegistration {
  IMMDeviceEnumerator* enumerator = nullptr;
  OutputDeviceEvents* events = nullptr;
  ~NotificationRegistration() {
    if (enumerator && events)
      enumerator->UnregisterEndpointNotificationCallback(events);
    if (events) events->Release();
  }
};

struct WasapiEndpoint {
  ComPtr<IAudioClient> client;
  ComPtr<IAudioRenderClient> render;
  HANDLE event = nullptr;
  UINT32 capacity = 0;
  int64_t latency_us = 0;
  int channels = 0;
  int block_align = 4;
  int rate = 48000;
  bool exclusive = false;
  int period_bytes = 0;
  int kind = 0;

  void Close() {
    if (client) {
      client->Stop();
      client.Reset();
    }
    render.Reset();
    if (event) CloseHandle(event);
    event = nullptr;
    capacity = 0;
    channels = 0;
    exclusive = false;
    period_bytes = 0;
    kind = 0;
    block_align = 4;
    rate = 48000;
  }
  ~WasapiEndpoint() { Close(); }
};

void OpenShared(IMMDevice* device, int channels, WasapiEndpoint* endpoint) {
  endpoint->Close();
  endpoint->event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (!endpoint->event) throw std::runtime_error("WASAPI event creation failed");
  Check(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                         reinterpret_cast<void**>(endpoint->client.GetAddressOf())),
        "WASAPI client unavailable");
  WAVEFORMATEX format{};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = static_cast<WORD>(channels);
  format.nSamplesPerSec = 48000;
  format.wBitsPerSample = 16;
  format.nBlockAlign = static_cast<WORD>(channels * 2);
  format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
  Check(endpoint->client->Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
            1200000, 0, &format, nullptr),
        "WASAPI PCM output initialization failed");
  Check(endpoint->client->SetEventHandle(endpoint->event),
        "WASAPI event registration failed");
  Check(endpoint->client->GetBufferSize(&endpoint->capacity),
        "WASAPI buffer size unavailable");
  REFERENCE_TIME ticks = 0;
  if (FAILED(endpoint->client->GetStreamLatency(&ticks))) ticks = 0;
  endpoint->latency_us = std::max<int64_t>(0, ticks / 10);
  Check(endpoint->client->GetService(IID_PPV_ARGS(&endpoint->render)),
        "WASAPI render service unavailable");
  endpoint->channels = channels;
  endpoint->block_align = format.nBlockAlign;
  endpoint->rate = 48000;
}

rillight_windows::ExclusiveProbe OpenExclusive(IMMDevice* device, int kind,
                                                     WasapiEndpoint* endpoint) {
  const bool truehd = kind == RILLIGHT_CORE_PASSTHROUGH_TRUEHD;
  endpoint->Close();
  endpoint->event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (!endpoint->event) return rillight_windows::ExclusiveProbe::kUnsupported;
  const HRESULT activated = device->Activate(
      __uuidof(IAudioClient), CLSCTX_ALL, nullptr,
      reinterpret_cast<void**>(endpoint->client.GetAddressOf()));
  const auto activation = rillight_windows::ClassifyExclusiveCall(activated);
  if (activation != rillight_windows::ExclusiveStep::kContinue) {
    endpoint->Close();
    return ProbeFromStep(activation);
  }
  const IecWave format = MakeIecFormat(truehd);
  const REFERENCE_TIME period = truehd ? 200000 : 320000;
  const HRESULT started = endpoint->client->Initialize(
      AUDCLNT_SHAREMODE_EXCLUSIVE, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, period,
      period, reinterpret_cast<const WAVEFORMATEX*>(&format), nullptr);
  const auto init = rillight_windows::ClassifyExclusiveCall(started);
  if (init != rillight_windows::ExclusiveStep::kContinue) {
    endpoint->Close();
    return ProbeFromStep(init);
  }
  const HRESULT event_hr = endpoint->client->SetEventHandle(endpoint->event);
  const HRESULT size_hr = SUCCEEDED(event_hr)
                              ? endpoint->client->GetBufferSize(&endpoint->capacity)
                              : S_OK;
  const HRESULT service_hr =
      SUCCEEDED(event_hr) && SUCCEEDED(size_hr)
          ? endpoint->client->GetService(IID_PPV_ARGS(&endpoint->render))
          : S_OK;
  if (FAILED(event_hr) || FAILED(size_hr) || FAILED(service_hr)) {
    const HRESULT failed = FAILED(event_hr)   ? event_hr
                           : FAILED(size_hr) ? size_hr
                                             : service_hr;
    endpoint->Close();
    return FailedProbe(failed);
  }
  const int expected = truehd ? RillightIec61937Mux::kTrueHdPeriod
                              : RillightIec61937Mux::kEac3Period;
  if (static_cast<int>(endpoint->capacity) * format.ext.Format.nBlockAlign !=
      expected) {
    endpoint->Close();
    return rillight_windows::ExclusiveProbe::kUnsupported;
  }
  REFERENCE_TIME ticks = 0;
  if (FAILED(endpoint->client->GetStreamLatency(&ticks))) ticks = 0;
  endpoint->latency_us = std::max<int64_t>(0, ticks / 10);
  endpoint->channels = format.ext.Format.nChannels;
  endpoint->block_align = format.ext.Format.nBlockAlign;
  endpoint->rate = 192000;
  endpoint->exclusive = true;
  endpoint->period_bytes = expected;
  endpoint->kind = kind;
  return rillight_windows::ExclusiveProbe::kAccepted;
}
}  // namespace

AudioOutput::AudioOutput(RillightCore* core, std::shared_ptr<CoreApi> api)
    : core_(core), api_(std::move(api)) {}

AudioOutput::~AudioOutput() { Stop(); }

void AudioOutput::Start() {
#if defined(_DEBUG)
  const bool suppressed =
      GetEnvironmentVariableW(L"RILLIGHT_TEST_NO_AUDIO", nullptr, 0) > 0;
#else
  const bool suppressed = false;
#endif
  if (!suppressed) {
    const HRESULT apartment = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (SUCCEEDED(apartment)) {
      try {
        const rillight_windows::RouteObservation observed = ProbeDevice();
        const rillight_windows::RouteCommit commit =
            rillight_windows::DecideAudioRoute(
                max_pcm_channels_, accepted_passthrough_, observed);
        if (commit.publish) {
          RillightCoreAudioSink sink{};
          sink.struct_size = sizeof(sink);
          sink.max_pcm_channels = commit.max_pcm_channels;
          sink.accepted_passthrough = commit.accepted_passthrough;
          sink.reports_atmos = 0;
          if (api_->configure_audio_sink(core_, &sink) == 0) {
            max_pcm_channels_ = commit.max_pcm_channels;
            accepted_passthrough_ = commit.accepted_passthrough;
          }
        }
      } catch (...) {
      }
      if (apartment == S_OK) CoUninitialize();
    }
  }
  worker_ = std::thread([this] { Run(); });
}

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

void AudioOutput::PublishSink() {
  RillightCoreAudioSink sink{};
  sink.struct_size = sizeof(sink);
  sink.max_pcm_channels = max_pcm_channels_;
  sink.accepted_passthrough = accepted_passthrough_;
  sink.reports_atmos = 0;
  api_->configure_audio_sink(core_, &sink);
}

void AudioOutput::ForgetPassthrough(uint32_t kind_bit) {
  accepted_passthrough_ &= ~kind_bit;
  PublishSink();
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
    NotificationRegistration notifications;
    notifications.events = new OutputDeviceEvents(&device_generation_);
    if (FAILED(enumerator->RegisterEndpointNotificationCallback(
            notifications.events))) {
      notifications.events->Release();
      notifications.events = nullptr;
    } else {
      notifications.enumerator = enumerator.Get();
    }
    const uint32_t route_at_start = device_generation_.load();
    WasapiEndpoint endpoint;
    RillightIec61937Mux mux;
    std::vector<uint8_t> burst;
    int64_t burst_pts = -1;
    int burst_samples = 0;

    uint64_t session = 0;
    uint64_t timeline = 0;
    int offset = 0;
    int64_t submitted_media_end = -1;
    bool handed_off_audio_clock = false;
    bool audio_clock_started = false;
    rillight_windows::AudioHandoffPolicy handoff_policy;
    bool running = false;
    int exclusive_stalls = 0;
    uint32_t seen_generation = route_at_start;
    auto retire_route = [&] {
      if (running && endpoint.client) endpoint.client->Stop();
      running = false;
      endpoint.Close();
      mux.reset();
      burst.clear();
      burst_pts = -1;
      burst_samples = 0;
      if (pending) api_->release_frame(pending);
      pending = nullptr;
      pending_ = false;
      device_padding_ = 0;
      offset = 0;
      submitted_media_end = -1;
      handed_off_audio_clock = false;
      audio_clock_started = false;
    };
    while (!stopped_) {
      RillightCoreSnapshot state{};
      state.struct_size = sizeof(state);
      if (api_->snapshot(core_, &state) != 0) break;
      if (state.session_id != session || state.timeline_version != timeline) {
        if (running && endpoint.client)
          Check(endpoint.client->Stop(), "WASAPI stop failed");
        running = false;
        if (endpoint.client)
          Check(endpoint.client->Reset(), "WASAPI timeline reset failed");
        if (pending) api_->release_frame(pending);
        pending = nullptr;
        pending_ = false;
        device_padding_ = 0;
        offset = 0;
        submitted_media_end = -1;
        handed_off_audio_clock = false;
        audio_clock_started = false;
        handoff_policy.Reset();
        mux.reset();
        burst.clear();
        burst_pts = -1;
        burst_samples = 0;
        exclusive_stalls = 0;
        session = state.session_id;
        timeline = state.timeline_version;
      }
      const uint32_t generation = device_generation_.load();
      if (generation != seen_generation) {
        seen_generation = generation;
        // IsFormatSupported/Initialize return DEVICE_IN_USE while this
        // process still holds the endpoint. Release first, then probe.
        retire_route();
        exclusive_stalls = 0;
        const rillight_windows::RouteObservation observed =
            ProbeDefaultRoute(enumerator.Get(), &device);
        const rillight_windows::RouteCommit commit =
            rillight_windows::DecideAudioRoute(
                max_pcm_channels_, accepted_passthrough_, observed);
        if (commit.publish) {
          max_pcm_channels_ = commit.max_pcm_channels;
          accepted_passthrough_ = commit.accepted_passthrough;
          PublishSink();
        }
      }
      if (!Active(state)) {
        if (running && endpoint.client)
          Check(endpoint.client->Stop(), "WASAPI pause failed");
        running = false;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        continue;
      }
      UINT32 padding = 0;
      if (endpoint.client)
        Check(endpoint.client->GetCurrentPadding(&padding),
              "WASAPI padding unavailable");
      device_padding_ = padding;
      const bool device_room =
          !endpoint.client || endpoint.capacity > padding;
      if (!pending && burst.empty() &&
          (device_room || mux.pending_input())) {
        pending = api_->take_frame(core_, RILLIGHT_CORE_AUDIO_S16);
        pending_ = pending != nullptr;
        offset = 0;
      }
      bool waiting_future_audio = false;
      bool wrote_audio = false;
      auto fail_passthrough = [&](int kind) {
        const uint32_t bit = kind == RILLIGHT_CORE_PASSTHROUGH_TRUEHD
                                 ? RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD
                                 : RILLIGHT_CORE_AUDIO_ACCEPT_EAC3;
        ForgetPassthrough(bit);
        mux.reset();
        burst.clear();
        burst_pts = -1;
        burst_samples = 0;
        if (endpoint.exclusive) {
          if (running) endpoint.client->Stop();
          running = false;
          endpoint.Close();
        }
        if (pending) api_->release_frame(pending);
        pending = nullptr;
        pending_ = false;
        device_padding_ = 0;
        exclusive_stalls = 0;
        if (device) {
          OpenShared(device.Get(), std::max(2, max_pcm_channels_), &endpoint);
        }
      };
      if (pending && pending->type == RILLIGHT_CORE_AUDIO_PASSTHROUGH) {
        const int kind = pending->audio_codec_id;
        const uint32_t bit = kind == RILLIGHT_CORE_PASSTHROUGH_TRUEHD
                                 ? RILLIGHT_CORE_AUDIO_ACCEPT_TRUEHD
                                 : RILLIGHT_CORE_AUDIO_ACCEPT_EAC3;
        if (pending->session_id != session ||
            pending->timeline_version != timeline || !pending->data ||
            pending->data_size <= 0 ||
            (kind != RILLIGHT_CORE_PASSTHROUGH_EAC3_JOC &&
             kind != RILLIGHT_CORE_PASSTHROUGH_TRUEHD) ||
            (accepted_passthrough_ & bit) == 0) {
          api_->release_frame(pending);
          pending = nullptr;
          pending_ = false;
        } else if (!endpoint.exclusive || endpoint.kind != kind) {
          if (running && endpoint.client) endpoint.client->Stop();
          running = false;
          auto opened = OpenExclusive(device.Get(), kind, &endpoint);
          auto action = rillight_windows::DecideExclusiveOpen(
              opened, exclusive_stalls);
          if (action == rillight_windows::ExclusiveOpenAction::kRefresh) {
            const rillight_windows::RouteObservation observed =
                ProbeDefaultRoute(enumerator.Get(), &device);
            const rillight_windows::RouteCommit commit =
                rillight_windows::DecideAudioRoute(
                    max_pcm_channels_, accepted_passthrough_, observed);
            if (commit.publish) {
              max_pcm_channels_ = commit.max_pcm_channels;
              accepted_passthrough_ = commit.accepted_passthrough;
              PublishSink();
            }
            if ((accepted_passthrough_ & bit) == 0 || !device) {
              action = rillight_windows::ExclusiveOpenAction::kUsePcm;
            } else {
              opened = OpenExclusive(device.Get(), kind, &endpoint);
              action = opened == rillight_windows::ExclusiveProbe::kEndpointLost
                           ? rillight_windows::ExclusiveOpenAction::kUsePcm
                           : rillight_windows::DecideExclusiveOpen(
                                 opened, exclusive_stalls);
            }
          }
          if (action == rillight_windows::ExclusiveOpenAction::kRetry) {
            // A single busy endpoint is not rejection. Stop after the limit
            // instead of holding compressed frames with no PCM fallback.
            ++exclusive_stalls;
            device_padding_ = 0;
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            continue;
          }
          if (action != rillight_windows::ExclusiveOpenAction::kPlay) {
            fail_passthrough(kind);
          } else {
            exclusive_stalls = 0;
          }
        }
        if (pending && pending->type == RILLIGHT_CORE_AUDIO_PASSTHROUGH) {
          std::vector<uint8_t> produced;
          const int packed = kind == RILLIGHT_CORE_PASSTHROUGH_TRUEHD
                                 ? mux.push_truehd(pending->data,
                                                   pending->data_size, &produced)
                                 : mux.push_eac3(pending->data, pending->data_size,
                                                 &produced);
          if (packed < 0) {
            fail_passthrough(kind);
          } else {
            if (burst_pts < 0) burst_pts = pending->pts_us;
            if (pending->sample_count > 0) burst_samples += pending->sample_count;
            api_->release_frame(pending);
            pending = nullptr;
            pending_ = false;
            if (packed == 1) burst = std::move(produced);
          }
        }
      }
      if (!burst.empty() && endpoint.exclusive && endpoint.client) {
        const UINT32 period_frames = static_cast<UINT32>(
            endpoint.period_bytes / endpoint.block_align);
        if (endpoint.capacity >= padding + period_frames &&
            static_cast<int>(burst.size()) == endpoint.period_bytes) {
          BYTE* output = nullptr;
          Check(endpoint.render->GetBuffer(period_frames, &output),
                "WASAPI buffer unavailable");
          std::memcpy(output, burst.data(), burst.size());
          Check(endpoint.render->ReleaseBuffer(period_frames, 0),
                "WASAPI buffer commit failed");
          device_padding_ = padding + period_frames;
          wrote_audio = true;
          if (burst_pts >= 0) {
            const int samples = burst_samples > 0 ? burst_samples : 1536;
            submitted_media_end = burst_pts + static_cast<int64_t>(
                samples * 1000000.0 / 48000.0 * state.playback_speed);
          }
          burst.clear();
          burst_pts = -1;
          burst_samples = 0;
        }
      }
      if (pending && pending->type != RILLIGHT_CORE_AUDIO_PASSTHROUGH) {
        const int stride = rillight_core_pcm_bytes_per_frame(pending);
        if (pending->session_id != session ||
            pending->timeline_version != timeline || !pending->data ||
            pending->sample_rate != 48000 || pending->channels < 1 ||
            pending->sample_count < 0 ||
            static_cast<int64_t>(pending->data_size) <
                static_cast<int64_t>(pending->sample_count) * stride) {
          api_->release_frame(pending);
          pending = nullptr;
          pending_ = false;
        } else {
          if (endpoint.exclusive || !endpoint.client ||
              endpoint.channels != pending->channels) {
            if (running && endpoint.client) endpoint.client->Stop();
            running = false;
            OpenShared(device.Get(), pending->channels, &endpoint);
            padding = 0;
            device_padding_ = 0;
          }
          if (!audio_clock_started && pending->pts_us >= 0) {
            if (pending->pts_us > state.position_us + 50000) {
              std::this_thread::sleep_for(std::chrono::milliseconds(4));
              continue;
            }
            offset = std::max(offset, rillight_windows::StartupSampleOffset(
                *pending, state.position_us, state.playback_speed));
          }
          if (audio_clock_started &&
              rillight_windows::WaitForFutureAudio(pending->pts_us,
                  state.position_us, submitted_media_end)) {
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
            } else if (endpoint.capacity > padding) {
              const UINT32 count = std::min<UINT32>(
                  endpoint.capacity - padding,
                  static_cast<UINT32>(pending->sample_count - offset));
              if (count > 0) {
                BYTE* output = nullptr;
                Check(endpoint.render->GetBuffer(count, &output),
                      "WASAPI buffer unavailable");
                std::memcpy(output,
                            pending->data + static_cast<size_t>(offset) * stride,
                            static_cast<size_t>(count) * stride);
                Check(endpoint.render->ReleaseBuffer(count, 0),
                      "WASAPI buffer commit failed");
                offset += static_cast<int>(count);
                wrote_audio = true;
                device_padding_ = padding + count;
                if (pending->pts_us >= 0) {
                  submitted_media_end = pending->pts_us + static_cast<int64_t>(
                      offset * 1000000.0 / 48000.0 * state.playback_speed);
                }
              }
              if (pending && offset >= pending->sample_count) {
                api_->release_frame(pending);
                pending = nullptr;
                pending_ = false;
              }
            }
          }
        }
      }
      if (!running && endpoint.client && device_padding_ > 0) {
        Check(endpoint.client->Start(), "WASAPI playback start failed");
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
          const int rate = endpoint.rate > 0 ? endpoint.rate : 48000;
          const int64_t queued_media_us = static_cast<int64_t>(
              device_padding_.load() * 1000000.0 / rate *
              state.playback_speed) + static_cast<int64_t>(
                  endpoint.latency_us * state.playback_speed);
          if (api_->report_audio_played(core_, session, timeline,
                                        submitted_media_end,
                                        queued_media_us) == 0) {
            audio_clock_started = true;
          } else if (!audio_clock_started && endpoint.client) {
            if (running) Check(endpoint.client->Stop(), "WASAPI realign stop failed");
            running = false;
            Check(endpoint.client->Reset(), "WASAPI realign reset failed");
            device_padding_ = 0;
            submitted_media_end = -1;
          }
        }
      }
      if (!wrote_audio || !endpoint.client ||
          device_padding_ >= endpoint.capacity) {
        if (endpoint.event)
          WaitForSingleObject(endpoint.event, running ? 5 : 4);
        else
          std::this_thread::sleep_for(std::chrono::milliseconds(4));
      }
    }
    if (running && endpoint.client) endpoint.client->Stop();
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
