#include <stddef.h>
#include <stdint.h>
#include <string.h>

#if defined(_WIN32)
#define CRC_API __declspec(dllexport)
#else
#define CRC_API __attribute__((visibility("default")))
#endif

#if defined(__x86_64__) || defined(__i386__) || defined(_M_X64) || defined(_M_IX86)
#define CRC_X86 1
#if defined(_MSC_VER)
#include <intrin.h>
#define RILLIGHT_PCLMUL_TARGET
#define RILLIGHT_ALIGN16 __declspec(align(16))
#else
#include <cpuid.h>
// Never enable the extended ISA for the whole library: older CPUs must be
// able to enter the dispatcher and software implementation safely.
#define RILLIGHT_PCLMUL_TARGET __attribute__((target("pclmul,sse4.1")))
#define RILLIGHT_ALIGN16 __attribute__((aligned(16)))
#endif
#include "crc32_pclmul.h"
#endif

#if (defined(__arm__) || defined(__aarch64__)) && defined(__clang__)
#define CRC_ARM 1
#if defined(__aarch64__)
#include <arm_acle.h>
#define ARM_CRC_TARGET __attribute__((target("crc")))
#define ARM_CRC_BYTE __crc32b
#define ARM_CRC_WORD __crc32w
#define ARM_CRC_DWORD __crc32d
#else
// Android armeabi-v7a is built for an ARMv7 baseline. Intrinsic declarations
// are hidden in arm_acle.h there; these builtins are function-targeted instead.
#define ARM_CRC_TARGET __attribute__((target("crc")))
#define ARM_CRC_BYTE __builtin_arm_crc32b
#define ARM_CRC_WORD __builtin_arm_crc32w
#endif
#if defined(__linux__)
#include <sys/auxv.h>
#elif defined(__APPLE__)
#include <sys/sysctl.h>
#endif

ARM_CRC_TARGET
static uint32_t crc32_arm(uint32_t crc, const uint8_t *bytes, size_t length) {
#if defined(__aarch64__)
  while (length >= 8) {
    uint64_t word;
    memcpy(&word, bytes, sizeof(word));
    crc = ARM_CRC_DWORD(crc, word);
    bytes += 8;
    length -= 8;
  }
#endif
  while (length >= 4) {
    uint32_t word;
    memcpy(&word, bytes, sizeof(word));
    crc = ARM_CRC_WORD(crc, word);
    bytes += 4;
    length -= 4;
  }
  while (length--) crc = ARM_CRC_BYTE(crc, *bytes++);
  return crc;
}
#endif

// IEEE's reflected polynomial 0xedb88320. A small read-only nibble table keeps
// the baseline implementation thread-safe without lazy mutable initialization.
static uint32_t crc32_software(uint32_t crc, const uint8_t *bytes, size_t length) {
  static const uint32_t table[16] = {
      0x00000000, 0x1db71064, 0x3b6e20c8, 0x26d930ac,
      0x76dc4190, 0x6b6b51f4, 0x4db26158, 0x5005713c,
      0xedb88320, 0xf00f9344, 0xd6d6a3e8, 0xcb61b38c,
      0x9b64c2b0, 0x86d3d2d4, 0xa00ae278, 0xbdbdf21c};
  while (length--) {
    crc ^= *bytes++;
    crc = (crc >> 4) ^ table[crc & 15];
    crc = (crc >> 4) ^ table[crc & 15];
  }
  return crc;
}

// 0: native software, 1: ARM CRC32, 2: x86 PCLMUL. No model/brand heuristic.
CRC_API int rillight_crc32_backend(void) {
#if defined(CRC_X86)
  uint32_t features;
#if defined(_MSC_VER)
  int registers[4];
  __cpuid(registers, 1);
  features = (uint32_t)registers[2];
#else
  unsigned int a, b, c, d;
  if (!__get_cpuid(1, &a, &b, &c, &d)) return 0;
  features = c;
#endif
  // SSE4.1 (extract_epi32) and PCLMULQDQ. SSE4.2 CRC32 computes CRC32C and
  // is deliberately never used for these persisted IEEE checksums.
  const uint32_t required = (1u << 19) | (1u << 1);
  return (features & required) == required ? 2 : 0;
#elif defined(CRC_ARM)
#if defined(__linux__) && defined(__aarch64__)
  return (getauxval(AT_HWCAP) & (1ul << 7)) ? 1 : 0; // HWCAP_CRC32
#elif defined(__linux__)
  return (getauxval(AT_HWCAP2) & (1ul << 4)) ? 1 : 0; // HWCAP2_CRC32
#elif defined(__APPLE__)
  int supported = 0;
  size_t length = sizeof(supported);
  return sysctlbyname("hw.optional.armv8_crc32", &supported, &length, NULL, 0) == 0
             && supported ? 1 : 0;
#else
  return 0;
#endif
#else
  return 0;
#endif
}

CRC_API uint32_t rillight_crc32_software(uint32_t previous,
                                       const uint8_t *bytes, size_t length) {
  return crc32_software(previous ^ UINT32_MAX, bytes, length) ^ UINT32_MAX;
}

// Leaf FFI entry: the caller has already selected a supported CPU backend.
// No system queries, allocation, retained pointers or Dart callbacks here.
// Dart limits each borrowed-typed-data call to 64 KiB so GC can run between
// chunks, including on CPUs that use the baseline software implementation.
CRC_API uint32_t rillight_crc32_chunk(uint32_t previous,
                                    const uint8_t *bytes, size_t length,
                                    int backend) {
  uint32_t crc = previous ^ UINT32_MAX;
#if defined(CRC_ARM)
  if (backend == 1) return crc32_arm(crc, bytes, length) ^ UINT32_MAX;
#elif defined(CRC_X86)
  if (backend == 2 && length >= 64) {
    const size_t bulk = length & ~(size_t)15;
    crc = crc32_pclmul(bytes, bulk, crc);
    bytes += bulk;
    length -= bulk;
  }
#else
  (void)backend;
#endif
  return crc32_software(crc, bytes, length) ^ UINT32_MAX;
}

CRC_API uint32_t rillight_crc32(uint32_t previous,
                              const uint8_t *bytes, size_t length) {
  return rillight_crc32_chunk(previous, bytes, length, rillight_crc32_backend());
}
