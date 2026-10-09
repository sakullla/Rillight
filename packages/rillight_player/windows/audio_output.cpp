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
#include "audio_transport.h"
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

IecWave MakeIecFormat(int kind, int source_rate = 48000,
                      int source_channels = 6, int samples = 512) {
  const auto transport = rillight_windows::EncodedTransport(kind, source_rate, samples);
  IecWave format{};
  format.ext.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
  format.ext.Format.nChannels = static_cast<WORD>(transport.channels);
  format.ext.Format.nSamplesPerSec = transport.rate;
  format.ext.Format.wBitsPerSample = 16;
  format.ext.Format.nBlockAlign = static_cast<WORD>(transport.channels * 2);
  format.ext.Format.nAvgBytesPerSec = transport.rate * format.ext.Format.nBlockAlign;
  format.ext.Format.cbSize = static_cast<WORD>(sizeof(IecWave) - sizeof(WAVEFORMATEX));
  format.ext.Samples.wValidBitsPerSample = 16;
  format.ext.dwChannelMask = transport.channels == 8 ? 0x63F : 0x3;
  format.ext.SubFormat = kIecEac3;
  if (kind == RILLIGHT_CORE_PASSTHROUGH_TRUEHD) format.ext.SubFormat = kIecTrueHd;
  if (kind == RILLIGHT_CORE_PASSTHROUGH_AC3 || kind == RILLIGHT_CORE_PASSTHROUGH_DTS) {
    format.ext.SubFormat = GUID{kind == RILLIGHT_CORE_PASSTHROUGH_AC3 ? 0x92u : 8u,
        0, 0x10, {0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71}};
  }
  if (kind == RILLIGHT_CORE_PASSTHROUGH_DTSHD) {
    format.ext.SubFormat = kIecTrueHd;
    format.ext.SubFormat.Data1 = 0x0b;
  }
  format.encoded_rate = source_rate;
  format.encoded_channels = static_cast<DWORD>(source_channels);
  // The compressed average bitrate is unknown; do not substitute the carrier rate.
  format.average_bytes = 0;
  return format;
}

REFERENCE_TIME IecPeriodTime(const rillight_windows::IecTransport& transport) {
  return static_cast<REFERENCE_TIME>((int64_t(transport.period_bytes) * 10000000 +
      transport.rate * transport.channels) / (transport.rate * transport.channels * 2));
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
                                                int kind) {
  ComPtr<IAudioClient> client;
  const HRESULT activated = device->Activate(
      __uuidof(IAudioClient), CLSCTX_ALL, nullptr,
      reinterpret_cast<void**>(client.GetAddressOf()));
  const auto activation = rillight_windows::ClassifyExclusiveCall(activated);
  if (activation != rillight_windows::ExclusiveStep::kContinue)
    return ProbeFromStep(activation);
  const IecWave format = MakeIecFormat(kind);
  const auto transport = rillight_windows::EncodedTransport(kind, 48000);
  const HRESULT supported = client->IsFormatSupported(
      AUDCLNT_SHAREMODE_EXCLUSIVE,
      reinterpret_cast<const WAVEFORMATEX*>(&format), nullptr);
  const auto support = rillight_windows::ClassifyExclusiveCall(supported);
  if (support != rillight_windows::ExclusiveStep::kContinue)
    return ProbeFromStep(support);
  HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (!event) return rillight_windows::ExclusiveProbe::kUnsupported;
  const REFERENCE_TIME period = IecPeriodTime(transport);
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
      const int expected = transport.period_bytes;
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
    result.truehd = result.ac3 = result.dts = result.dtshd =
        rillight_windows::ExclusiveProbe::kUnsupported;
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
  const std::pair<int, rillight_windows::ExclusiveProbe*> probes[] = {
      {RILLIGHT_CORE_PASSTHROUGH_EAC3, &result.eac3},
      {RILLIGHT_CORE_PASSTHROUGH_TRUEHD, &result.truehd},
      {RILLIGHT_CORE_PASSTHROUGH_AC3, &result.ac3},
      {RILLIGHT_CORE_PASSTHROUGH_DTS, &result.dts},
      {RILLIGHT_CORE_PASSTHROUGH_DTSHD, &result.dtshd}};
  for (const auto& probe : probes) {
    *probe.second = ProbeExclusive(device, probe.first);
    if (*probe.second == rillight_windows::ExclusiveProbe::kDeviceInUse) {
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
      *probe.second = ProbeExclusive(device, probe.first);
    }
    if (*probe.second == rillight_windows::ExclusiveProbe::kEndpointLost) {
      result.endpoint_lost = true;
      break;
    }
  }
  return result;
}

// Refreshes the default endpoint once after DEVICE_INVALIDATED or
// ENDPOINT_CREATE_FAILED. A second loss stays endpoint_lost and clears
// *device so the caller cannot Initialize that IMMDevice.
rillight_windows::RouteObservation ProbeDefaultRoute(
    IMMDeviceEnumerator* enumerator, ComPtr<IMMDevice>* device) {
  ComPtr<IMMDevice> current;
  if (!enumerator ||
      FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole,
                                                 &current))) {
    if (device) device->Reset();
    return {};
  }
  auto observed = ProbeOpenDevice(current.Get());
  if (observed.endpoint_lost) {
    ComPtr<IMMDevice> refreshed;
    if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole,
                                                   &refreshed))) {
      if (device) device->Reset();
      return {};
    }
    current = refreshed;
    observed = rillight_windows::RouteAfterEndpointLoss(
        ProbeOpenDevice(current.Get()));
  }
  if (device) {
    if (rillight_windows::SharedInitializeAllowed(observed)) *device = current;
    else device->Reset();
  }
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

// DEVICE_INVALIDATED, ENDPOINT_CREATE_FAILED, and DEVICE_IN_USE close the
// client and return. They must not throw out of the audio thread.
rillight_windows::SharedInitResult OpenShared(IMMDevice* device, int channels,
                                              WasapiEndpoint* endpoint) {
  endpoint->Close();
  if (!device || channels < 1)
    return rillight_windows::SharedInitResult::kWaitForGeneration;
  endpoint->event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (!endpoint->event) return rillight_windows::SharedInitResult::kFatal;
  auto finish = [&](HRESULT hr) {
    const auto result =
        rillight_windows::ClassifySharedInit(static_cast<int32_t>(hr));
    if (result != rillight_windows::SharedInitResult::kReady) endpoint->Close();
    return result;
  };
  const HRESULT activated = device->Activate(
      __uuidof(IAudioClient), CLSCTX_ALL, nullptr,
      reinterpret_cast<void**>(endpoint->client.GetAddressOf()));
  if (FAILED(activated)) return finish(activated);
  WAVEFORMATEX format{};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = static_cast<WORD>(channels);
  format.nSamplesPerSec = 48000;
  format.wBitsPerSample = 16;
  format.nBlockAlign = static_cast<WORD>(channels * 2);
  format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
  const HRESULT initialized = endpoint->client->Initialize(
      AUDCLNT_SHAREMODE_SHARED,
      AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
          AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
      1200000, 0, &format, nullptr);
  if (FAILED(initialized)) return finish(initialized);
  const HRESULT event_hr = endpoint->client->SetEventHandle(endpoint->event);
  if (FAILED(event_hr)) return finish(event_hr);
  const HRESULT size_hr = endpoint->client->GetBufferSize(&endpoint->capacity);
  if (FAILED(size_hr)) return finish(size_hr);
  REFERENCE_TIME ticks = 0;
  if (FAILED(endpoint->client->GetStreamLatency(&ticks))) ticks = 0;
  const HRESULT service_hr =
      endpoint->client->GetService(IID_PPV_ARGS(&endpoint->render));
  if (FAILED(service_hr)) return finish(service_hr);
  endpoint->latency_us = std::max<int64_t>(0, ticks / 10);
  endpoint->channels = channels;
  endpoint->block_align = format.nBlockAlign;
  endpoint->rate = 48000;
  return rillight_windows::SharedInitResult::kReady;
}

rillight_windows::ExclusiveProbe OpenExclusive(IMMDevice* device, int kind, int source_rate, int source_channels,
    int samples, WasapiEndpoint* endpoint) {
  const auto transport = rillight_windows::EncodedTransport(kind, source_rate, samples);
  if (transport.period_bytes == 0) return rillight_windows::ExclusiveProbe::kUnsupported;
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
  const IecWave format = MakeIecFormat(kind, source_rate, source_channels, samples);
  const REFERENCE_TIME period = IecPeriodTime(transport);
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
  const int expected = transport.period_bytes;
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
  endpoint->rate = transport.rate;
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
    // Non-zero while the last probe was endpoint_lost. Shared Initialize
    // waits until a newer default-device generation is actually openable.
    uint32_t awaiting_generation = 0;
    auto retire_route = [&] {
      if (running && endpoint.client) endpoint.client->Stop();
      running = false;
      endpoint.Close();
      mux.reset();
      burst.clear();
      burst_pts = -1;

      if (pending) api_->release_frame(pending);
      pending = nullptr;
      pending_ = false;
      device_padding_ = 0;
      offset = 0;
      submitted_media_end = -1;
      handed_off_audio_clock = false;
      audio_clock_started = false;
    };
    auto publish_route = [&](int channels, uint32_t accept) {
      if (channels == max_pcm_channels_ && accept == accepted_passthrough_)
        return;
      max_pcm_channels_ = channels;
      accepted_passthrough_ = accept;
      PublishSink();
    };
    auto drop_compressed = [&] {
      mux.reset();
      burst.clear();
      burst_pts = -1;

      exclusive_stalls = 0;
      if (pending && pending->type == RILLIGHT_CORE_AUDIO_PASSTHROUGH) {
        api_->release_frame(pending);
        pending = nullptr;
        pending_ = false;
      }
    };
    // A lost probe publishes stereo PCM and does not adopt that mix. A live
    // probe publishes the negotiated route, including passthrough when the
    // replacement receiver still accepts it.
    auto apply_probed_route =
        [&](const rillight_windows::RouteObservation& observed) {
          if (!rillight_windows::SharedInitializeAllowed(observed)) {
            device.Reset();
            awaiting_generation = device_generation_.load();
            publish_route(2, 0);
            return;
          }
          awaiting_generation = 0;
          const rillight_windows::RouteCommit commit =
              rillight_windows::DecideAudioRoute(
                  max_pcm_channels_, accepted_passthrough_, observed);
          if (commit.publish) {
            max_pcm_channels_ = commit.max_pcm_channels;
            accepted_passthrough_ = commit.accepted_passthrough;
            PublishSink();
          }
        };
    auto open_shared = [&](int channels) {
      if (!device || awaiting_generation != 0) {
        if (endpoint.client) endpoint.Close();
        running = false;
        if (awaiting_generation == 0)
          awaiting_generation = device_generation_.load();
        return rillight_windows::SharedInitResult::kWaitForGeneration;
      }
      const auto opened = OpenShared(device.Get(), channels, &endpoint);
      if (opened == rillight_windows::SharedInitResult::kWaitForGeneration) {
        device.Reset();
        awaiting_generation = device_generation_.load();
        drop_compressed();
        publish_route(2, 0);
      } else if (opened == rillight_windows::SharedInitResult::kFatal) {
        throw std::runtime_error("WASAPI PCM output initialization failed");
      }
      return opened;
    };
    auto fail_passthrough = [&](int kind) {
      const uint32_t bit = rillight_passthrough_accept_bit(kind);
      ForgetPassthrough(bit);
      drop_compressed();
      if (running && endpoint.client) endpoint.client->Stop();
      running = false;
      endpoint.Close();
      if (pending) api_->release_frame(pending);
      pending = nullptr;
      pending_ = false;
      device_padding_ = 0;
      exclusive_stalls = 0;
      open_shared(std::max(2, max_pcm_channels_));
    };
    auto on_endpoint_lost = [&] {
      if (running && endpoint.client) endpoint.client->Stop();
      running = false;
      endpoint.Close();
      device_padding_ = 0;
      drop_compressed();
      if (pending) {
        api_->release_frame(pending);
        pending = nullptr;
        pending_ = false;
      }
      submitted_media_end = -1;
      audio_clock_started = false;
      handed_off_audio_clock = false;
      offset = 0;
      // Clear passthrough before probing so the snapshot cannot stay
      // passthrough while this endpoint is gone.
      publish_route(2, 0);
      apply_probed_route(ProbeDefaultRoute(enumerator.Get(), &device));
    };
    // True when the audio thread must abandon this client and keep running.
    auto client_failed = [&](HRESULT hr, const char* message) -> bool {
      const auto fault = rillight_windows::ClassifyClientFault(
          static_cast<int32_t>(hr));
      if (fault == rillight_windows::ClientFault::kNone) return false;
      if (!rillight_windows::AudioThreadContinues(fault))
        throw std::runtime_error(message);
      const bool exclusive = endpoint.exclusive;
      const int kind = endpoint.kind;
      running = false;
      endpoint.Close();
      device_padding_ = 0;
      if (fault == rillight_windows::ClientFault::kLost) {
        on_endpoint_lost();
      } else {
        // The unsent period cannot be committed on a client we just closed.
        burst.clear();
        burst_pts = -1;

        if (exclusive && kind != 0) {
          ++exclusive_stalls;
          if (exclusive_stalls >= rillight_windows::kExclusiveOpenAttemptLimit)
            fail_passthrough(kind);
        }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
      return true;
    };
    while (!stopped_) {
      RillightCoreSnapshot state{};
      state.struct_size = sizeof(state);
      if (api_->snapshot(core_, &state) != 0) break;
      if (state.session_id != session || state.timeline_version != timeline) {
        bool client_replaced = false;
        if (running && endpoint.client) {
          const HRESULT hr = endpoint.client->Stop();
          client_replaced = client_failed(hr, "WASAPI stop failed");
          if (!client_replaced) running = false;
        } else {
          running = false;
        }
        if (endpoint.client && !client_replaced) {
          const HRESULT hr = endpoint.client->Reset();
          client_failed(hr, "WASAPI timeline reset failed");
        }
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
        apply_probed_route(ProbeDefaultRoute(enumerator.Get(), &device));
      }
      if (!Active(state)) {
        if (running && endpoint.client) {
          const HRESULT hr = endpoint.client->Stop();
          if (!client_failed(hr, "WASAPI pause failed")) running = false;
        } else {
          running = false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        continue;
      }
      UINT32 padding = 0;
      if (endpoint.client) {
        const HRESULT padding_hr = endpoint.client->GetCurrentPadding(&padding);
        if (client_failed(padding_hr, "WASAPI padding unavailable")) continue;
      }
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
      if (pending && pending->type == RILLIGHT_CORE_AUDIO_PASSTHROUGH) {
        const int kind = pending->audio_codec_id;
        const auto dts = rillight_dts_header(pending->data, pending->data_size);
        const int source_rate = kind == RILLIGHT_CORE_PASSTHROUGH_DTSHD && dts.rate
            ? dts.rate : pending->sample_rate;
        const int samples = dts.samples ? dts.samples : 512;
        const auto transport = rillight_windows::EncodedTransport(kind, source_rate, samples);
        const uint32_t bit = rillight_passthrough_accept_bit(kind);
        if (pending->session_id != session ||
            pending->timeline_version != timeline || !pending->data ||
            pending->data_size <= 0 ||
            bit == 0 ||
            (accepted_passthrough_ & bit) == 0) {
          api_->release_frame(pending);
          pending = nullptr;
          pending_ = false;
        } else if (!device) {
          fail_passthrough(kind);
        } else if (!endpoint.exclusive || endpoint.kind != kind ||
                   endpoint.rate != transport.rate ||
                   endpoint.period_bytes != transport.period_bytes) {
          if (running && endpoint.client) endpoint.client->Stop();
          running = false;
          auto opened = OpenExclusive(device.Get(), kind, source_rate, pending->channels, samples, &endpoint);
          auto action = rillight_windows::DecideExclusiveOpen(
              opened, exclusive_stalls);
          if (action == rillight_windows::ExclusiveOpenAction::kRefresh) {
            apply_probed_route(ProbeDefaultRoute(enumerator.Get(), &device));
            if ((accepted_passthrough_ & bit) == 0 || !device) {
              action = rillight_windows::ExclusiveOpenAction::kUsePcm;
            } else {
              opened = OpenExclusive(device.Get(), kind, source_rate, pending->channels, samples, &endpoint);
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
              ? mux.push_truehd(pending->data, pending->data_size, &produced)
              : kind == RILLIGHT_CORE_PASSTHROUGH_AC3
              ? mux.push_ac3(pending->data, pending->data_size, &produced)
              : kind == RILLIGHT_CORE_PASSTHROUGH_DTS || kind == RILLIGHT_CORE_PASSTHROUGH_DTSHD
              ? mux.push_dts(pending->data, pending->data_size,
                             kind == RILLIGHT_CORE_PASSTHROUGH_DTSHD, &produced)
              : mux.push_eac3(pending->data, pending->data_size, &produced);
          if (packed < 0) {
            fail_passthrough(kind);
          } else {
            if (burst_pts < 0) burst_pts = pending->pts_us;
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
        if (endpoint.render &&
            endpoint.capacity >= padding + period_frames &&
            static_cast<int>(burst.size()) == endpoint.period_bytes) {
          BYTE* output = nullptr;
          const HRESULT buffer_hr =
              endpoint.render->GetBuffer(period_frames, &output);
          if (client_failed(buffer_hr, "WASAPI buffer unavailable")) continue;
          std::memcpy(output, burst.data(), burst.size());
          const HRESULT release_hr =
              endpoint.render->ReleaseBuffer(period_frames, 0);
          if (client_failed(release_hr, "WASAPI buffer commit failed"))
            continue;
          device_padding_ = padding + period_frames;
          wrote_audio = true;
          if (burst_pts >= 0) {
            submitted_media_end = burst_pts + static_cast<int64_t>(
                endpoint.period_bytes * 1000000.0 /
                (endpoint.block_align * endpoint.rate));
          }
          burst.clear();
          burst_pts = -1;

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
            const auto opened = open_shared(pending->channels);
            if (opened != rillight_windows::SharedInitResult::kReady) {
              std::this_thread::sleep_for(std::chrono::milliseconds(20));
              continue;
            }
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
              if (count > 0 && endpoint.render) {
                BYTE* output = nullptr;
                const HRESULT buffer_hr =
                    endpoint.render->GetBuffer(count, &output);
                if (client_failed(buffer_hr, "WASAPI buffer unavailable"))
                  continue;
                std::memcpy(output,
                            pending->data + static_cast<size_t>(offset) * stride,
                            static_cast<size_t>(count) * stride);
                const HRESULT release_hr =
                    endpoint.render->ReleaseBuffer(count, 0);
                if (client_failed(release_hr, "WASAPI buffer commit failed"))
                  continue;
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
        const HRESULT hr = endpoint.client->Start();
        if (client_failed(hr, "WASAPI playback start failed")) continue;
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
            bool client_replaced = false;
            if (running) {
              const HRESULT hr = endpoint.client->Stop();
              client_replaced = client_failed(hr, "WASAPI realign stop failed");
              if (!client_replaced) running = false;
            }
            if (endpoint.client && !client_replaced) {
              const HRESULT hr = endpoint.client->Reset();
              client_replaced = client_failed(hr, "WASAPI realign reset failed");
            }
            if (!client_replaced) {
              device_padding_ = 0;
              submitted_media_end = -1;
            }
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
