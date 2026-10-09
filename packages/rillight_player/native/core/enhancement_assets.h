#ifndef RILLIGHT_ENHANCEMENT_ASSETS_H_
#define RILLIGHT_ENHANCEMENT_ASSETS_H_

#include <cstdlib>
#include <filesystem>
#include <vector>

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace rillight {

// Keep model and shader lookup on the same native path representation. ANSI
// Win32 paths lose characters when the installation is outside the code page.
inline std::filesystem::path EnhancementModuleDirectory() {
#if defined(_WIN32)
  HMODULE module = nullptr;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                            GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                        reinterpret_cast<LPCWSTR>(&EnhancementModuleDirectory), &module))
    return {};
  std::vector<wchar_t> buffer(512);
  while (buffer.size() <= 32768) {
    const DWORD length = GetModuleFileNameW(module, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (!length) return {};
    if (length < buffer.size())
      return std::filesystem::path(buffer.data(), buffer.data() + length).parent_path();
    buffer.resize(buffer.size() * 2);
  }
  return {};
#else
  Dl_info info{};
  if (dladdr(reinterpret_cast<const void*>(&EnhancementModuleDirectory), &info) == 0 ||
      !info.dli_fname) return {};
  return std::filesystem::path(info.dli_fname).parent_path();
#endif
}

inline std::filesystem::path EnhancementOverrideDirectory() {
#if defined(_WIN32)
  std::vector<wchar_t> buffer(512);
  for (;;) {
    const DWORD length = GetEnvironmentVariableW(
        L"RILLIGHT_ENHANCEMENT_DIR", buffer.data(), static_cast<DWORD>(buffer.size()));
    if (!length) return {};
    if (length < buffer.size())
      return std::filesystem::path(buffer.data(), buffer.data() + length);
    buffer.resize(length);
  }
#else
  const auto* value = std::getenv("RILLIGHT_ENHANCEMENT_DIR");
  return value ? std::filesystem::path(value) : std::filesystem::path{};
#endif
}

}  // namespace rillight
#endif
