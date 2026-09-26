#pragma once

#include <Windows.h>

#include <stdexcept>
#include <string>

#include "../native/core/rillight_core.h"

// The core is built from the pinned FFmpeg SDK. Loading its C ABI at runtime
// keeps the Flutter plugin independent of the compiler used for that SDK.
class CoreApi {
 public:
  CoreApi() {
    module_ = LoadLibraryExW(L"rillight_core.dll", nullptr,
                             LOAD_LIBRARY_SEARCH_APPLICATION_DIR);
    if (!module_) {
      module_ = LoadLibraryExW(L"librillight_core.dll", nullptr,
                               LOAD_LIBRARY_SEARCH_APPLICATION_DIR);
    }
    if (!module_) throw std::runtime_error("Rillight core DLL unavailable");
    try {
      abi_version = Resolve<decltype(abi_version)>("rillight_core_abi_version");
      configure_hardware = Resolve<decltype(configure_hardware)>(
          "rillight_core_configure_hardware");
      snapshot = Resolve<decltype(snapshot)>("rillight_core_snapshot");
      take_frame = Resolve<decltype(take_frame)>("rillight_core_take_frame");
      release_frame = Resolve<decltype(release_frame)>("rillight_core_release_frame");
      report_audio_played = Resolve<decltype(report_audio_played)>(
          "rillight_core_report_audio_played");
      report_audio_unavailable = Resolve<decltype(report_audio_unavailable)>(
          "rillight_core_report_audio_unavailable");
      report_output_drained = Resolve<decltype(report_output_drained)>(
          "rillight_core_report_output_drained");
      track_count = Resolve<decltype(track_count)>("rillight_core_track_count");
      get_track = Resolve<decltype(get_track)>("rillight_core_get_track");
      if (abi_version() != RILLIGHT_CORE_ABI_VERSION) {
        throw std::runtime_error("Rillight core ABI mismatch");
      }
    } catch (...) {
      FreeLibrary(module_);
      module_ = nullptr;
      throw;
    }
  }
  ~CoreApi() {
    if (module_) FreeLibrary(module_);
  }
  CoreApi(const CoreApi&) = delete;
  CoreApi& operator=(const CoreApi&) = delete;

  decltype(&rillight_core_abi_version) abi_version = nullptr;
  decltype(&rillight_core_configure_hardware) configure_hardware = nullptr;
  decltype(&rillight_core_snapshot) snapshot = nullptr;
  decltype(&rillight_core_take_frame) take_frame = nullptr;
  decltype(&rillight_core_release_frame) release_frame = nullptr;
  decltype(&rillight_core_report_audio_played) report_audio_played = nullptr;
  decltype(&rillight_core_report_audio_unavailable) report_audio_unavailable = nullptr;
  decltype(&rillight_core_report_output_drained) report_output_drained = nullptr;
  decltype(&rillight_core_track_count) track_count = nullptr;
  decltype(&rillight_core_get_track) get_track = nullptr;

 private:
  template <typename Function>
  Function Resolve(const char* name) {
    auto* address = GetProcAddress(module_, name);
    if (!address) throw std::runtime_error(std::string("Missing core ABI: ") + name);
    return reinterpret_cast<Function>(address);
  }
  HMODULE module_ = nullptr;
};
