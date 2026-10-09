#include "../core/video_enhancer.h"
#include "../core/enhancement_models.h"
#include "../core/anime4k_glsl.h"
#include "../core/enhancement_assets.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>

// Isolate the pixel/temporal policy from model files and GPU availability.
namespace rillight {
int model_queries = 0;
bool RifeReady() { ++model_queries; return true; }
bool SuperResolutionReady() { ++model_queries; return true; }
bool Anime4kShadersReady() { ++model_queries; return true; }
bool ApplyAnime4k(std::vector<float>*, std::vector<float>*, int*, int*, int, float) { return false; }
bool ApplySuperResolution(std::vector<float>*, std::vector<float>*, int*, int*, float) { return false; }
bool ApplyRife(const std::vector<float>& prior, const std::vector<float>& current,
               int, int, float, std::vector<float>* midpoint) {
  midpoint->resize(current.size());
  for (size_t i = 0; i < current.size(); ++i) (*midpoint)[i] = (prior[i] + current[i]) * .5f;
  return true;
}
}

namespace {
auto Request(int sharpen = 0) {
  RillightCoreEnhancementRequest request{};
  request.struct_size = sizeof(request);
  request.sharpen = sharpen;
  return request;
}

void CheckSharpen(int width, int height, int strength) {
  const int stride = width * 4 + 7;
  std::vector<uint8_t> src(static_cast<size_t>(stride) * height);
  uint32_t random = 42;
  for (auto& byte : src) {
    random = random * 1664525u + 1013904223u;
    byte = static_cast<uint8_t>(random >> 24);
  }
  rillight::VideoQualityEnhancer enhancer;
  assert(enhancer.Configure(Request(strength)) == 0);
  rillight::QualityProcessResult result;
  assert(enhancer.Process(src.data(), width, height, stride, 4, 0, 1,
                          nullptr, 0, 128u << 20, &result));
  assert(result.changed && result.width == width && result.height == height);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      for (int c = 0; c < 4; ++c) {
        const int actual = result.current[(y * width + x) * 4 + c];
        const float value = src[y * stride + x * 4 + c] / 255.0f;
        if (c == 3) { assert(actual == src[y * stride + x * 4 + c]); continue; }
        float sum = 0;
        for (int dy = -1; dy <= 1; ++dy)
          for (int dx = -1; dx <= 1; ++dx)
            sum += src[std::clamp(y + dy, 0, height - 1) * stride +
                       std::clamp(x + dx, 0, width - 1) * 4 + c] / 255.0f;
        const float amount = strength / 100.0f * 1.2f;
        const int expected = static_cast<int>(std::lround(std::clamp(
            value + amount * (value - sum / 9), 0.0f, 1.0f) * 255));
        // The separable sum can differ by one quantization step at a half tie.
        assert(std::abs(actual - expected) <= 1);
      }
    }
  }
}

void CheckHalfSubnormals() {
  rillight::VideoQualityEnhancer enhancer;
  assert(enhancer.Configure(Request(30)) == 0);
  rillight::QualityProcessResult result;
  // Constant pictures survive sharpening exactly, including dark HDR values.
  for (uint16_t value : {uint16_t(1), uint16_t(2), uint16_t(511), uint16_t(1023), uint16_t(1024)}) {
    uint16_t pixel[] = {value, value, value, 0x3c00};
    assert(enhancer.Process(reinterpret_cast<uint8_t*>(pixel), 1, 1, 8, 8,
                            0, 1, nullptr, 0, 1024, &result));
    assert(result.current.size() == sizeof(pixel));
    assert(std::memcmp(result.current.data(), pixel, sizeof(pixel)) == 0);
  }
}

void CheckTemporal() {
  auto request = Request(); request.interpolation = 2; request.display_refresh_hz = 120;
  rillight::VideoQualityEnhancer enhancer;
  assert(enhancer.Configure(request) == 0);
  enhancer.UpdatePlaybackFacts(0, 30);
  uint8_t pixel[] = {40, 40, 40, 255};
  rillight::QualityProcessResult result;
  auto process = [&](int64_t pts, uint64_t timeline) {
    assert(enhancer.Process(pixel, 1, 1, 4, 4, pts, timeline, nullptr, 0, 1024, &result));
  };
  process(100, 1); assert(!result.has_midpoint);
  process(200, 1); assert(result.has_midpoint && result.mid_pts_us == 150);
  process(200, 1); assert(!result.has_midpoint);
  process(50, 1); assert(!result.has_midpoint);
  process(300, 2); assert(!result.has_midpoint);
  enhancer.ResetTemporal(); process(400, 2); assert(!result.has_midpoint);
}

void CheckInvalidFacts() {
  auto request = Request(20);
  RillightCoreEnhancementFacts facts{};
  facts.struct_size = sizeof(facts); facts.picture_available = 1;
  RillightCoreEnhancementLoad load{}; load.struct_size = sizeof(load);
  uint8_t pixel[] = {10, 10, 10, 255}, output[4];
  int w = 0, h = 0, mid = 0;
  auto process = [&] { return rillight_enhancement_process_rgba(&request, &facts, &load,
      pixel, 1, 1, 4, nullptr, 0, output, 4, &w, &h, nullptr, 0, &mid); };
  facts.source_frame_rate = std::numeric_limits<double>::quiet_NaN();
  assert(process() == -1);
  facts.source_frame_rate = 30; load.drop_spatial = 2; assert(process() == -1);
  load.drop_spatial = 0; assert(process() == 0);
}

void Benchmark() {
  const int width = 1920, height = 1080;
  std::vector<uint8_t> src(width * height * 4);
  for (size_t i = 0; i < src.size(); ++i) src[i] = static_cast<uint8_t>(i * 71);
  rillight::VideoQualityEnhancer enhancer;
  assert(enhancer.Configure(Request(35)) == 0);
  rillight::QualityProcessResult result;
  double samples[15];
  for (int i = -3; i < 15; ++i) {
    const auto start = std::chrono::steady_clock::now();
    assert(enhancer.Process(src.data(), width, height, width * 4, 4, i, 1,
                            nullptr, 0, 128u << 20, &result));
    if (i >= 0) samples[i] = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - start).count();
  }
  std::sort(std::begin(samples), std::end(samples));
  std::printf("1080p RGBA sharpen median %.3f ms, 15 frames after 3 warmups\n", samples[7]);
}
}

int main(int argc, char**) {
  if (argc > 1) { Benchmark(); return 0; }
  assert(std::filesystem::is_directory(rillight::EnhancementModuleDirectory()));
#if defined(_WIN32)
  const auto override_before = rillight::EnhancementOverrideDirectory();
  const auto unicode_path = std::filesystem::temp_directory_path() /
      std::filesystem::path(L"\u675c\u6bd4-\u753b\u8d28-\u03a9");
  assert(_wputenv_s(L"RILLIGHT_ENHANCEMENT_DIR", unicode_path.c_str()) == 0);
  assert(rillight::EnhancementOverrideDirectory() == unicode_path);
  assert(_wputenv_s(L"RILLIGHT_ENHANCEMENT_DIR", override_before.c_str()) == 0);
#endif
  rillight::VideoQualityEnhancer enhancer;
  assert(enhancer.Configure(Request()) == 0);
  assert(!enhancer.NeedsReconstructedPicture());
  enhancer.UpdatePlaybackFacts(0, 30);
  assert(rillight::model_queries == 0);
  for (int strength : {1, 35, 100})
    for (const auto& size : {std::pair{1, 1}, std::pair{1, 17}, std::pair{19, 1},
                             std::pair{2, 2}, std::pair{17, 23}})
      CheckSharpen(size.first, size.second, strength);
  assert(rillight::model_queries == 0);
  CheckHalfSubnormals();
  CheckTemporal();
  CheckInvalidFacts();
  static_assert(RILLIGHT_CORE_VIDEO_ANDROID_TUNNEL != RILLIGHT_CORE_AUDIO_PASSTHROUGH);
  std::puts("video enhancer pixel, temporal and validation tests passed");
}
