#include "enhancement_models.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <vector>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#ifndef RILLIGHT_HAVE_NCNN
#define RILLIGHT_HAVE_NCNN 0
#endif

#if RILLIGHT_HAVE_NCNN
#include "layer.h"
#include "mat.h"
#include "net.h"
#endif

namespace rillight {
namespace {

uint32_t Rotr(uint32_t value, uint32_t bits) {
  return (value >> bits) | (value << (32 - bits));
}

std::string Sha256File(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) return {};
  std::string bytes((std::istreambuf_iterator<char>(input)),
                    std::istreambuf_iterator<char>());
  static const uint32_t kK[64] = {
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
      0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
      0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
      0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
      0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
      0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
      0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
      0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
      0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
  uint32_t state[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                       0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  const uint64_t bits = static_cast<uint64_t>(bytes.size()) * 8u;
  bytes.push_back(static_cast<char>(0x80));
  while ((bytes.size() % 64) != 56) bytes.push_back(0);
  for (int shift = 7; shift >= 0; --shift)
    bytes.push_back(static_cast<char>((bits >> (shift * 8)) & 0xffu));
  for (size_t offset = 0; offset < bytes.size(); offset += 64) {
    uint32_t word[64];
    for (int index = 0; index < 16; ++index) {
      const unsigned char* block = reinterpret_cast<const unsigned char*>(
          bytes.data() + offset + static_cast<size_t>(index) * 4u);
      word[index] = (static_cast<uint32_t>(block[0]) << 24) |
                    (static_cast<uint32_t>(block[1]) << 16) |
                    (static_cast<uint32_t>(block[2]) << 8) | block[3];
    }
    for (int index = 16; index < 64; ++index) {
      const uint32_t small = Rotr(word[index - 15], 7) ^ Rotr(word[index - 15], 18) ^
                             (word[index - 15] >> 3);
      const uint32_t large = Rotr(word[index - 2], 17) ^ Rotr(word[index - 2], 19) ^
                             (word[index - 2] >> 10);
      word[index] = word[index - 16] + small + word[index - 7] + large;
    }
    uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
    uint32_t e = state[4], f = state[5], g = state[6], h = state[7];
    for (int index = 0; index < 64; ++index) {
      const uint32_t temp1 = h + (Rotr(e, 6) ^ Rotr(e, 11) ^ Rotr(e, 25)) +
                             ((e & f) ^ ((~e) & g)) + kK[index] + word[index];
      const uint32_t temp2 = (Rotr(a, 2) ^ Rotr(a, 13) ^ Rotr(a, 22)) +
                             ((a & b) ^ (a & c) ^ (b & c));
      h = g;
      g = f;
      f = e;
      e = d + temp1;
      d = c;
      c = b;
      b = a;
      a = temp1 + temp2;
    }
    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
  }
  std::string hex;
  hex.reserve(64);
  for (uint32_t part : state) {
    for (int shift = 7; shift >= 0; --shift) {
      const int nibble = static_cast<int>((part >> (shift * 4)) & 0xfu);
      hex.push_back(static_cast<char>(nibble < 10 ? '0' + nibble : 'a' + nibble - 10));
    }
  }
  return hex;
}

std::filesystem::path ModuleDirectory() {
#if defined(_WIN32)
  HMODULE module = nullptr;
  if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                              GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                          reinterpret_cast<LPCSTR>(&ModuleDirectory), &module))
    return {};
  char buffer[MAX_PATH * 4] = {};
  const DWORD length = GetModuleFileNameA(module, buffer, sizeof(buffer));
  if (length == 0 || length >= sizeof(buffer)) return {};
  return std::filesystem::path(buffer).parent_path();
#else
  Dl_info info{};
  if (dladdr(reinterpret_cast<const void*>(&ModuleDirectory), &info) == 0 ||
      !info.dli_fname)
    return {};
  return std::filesystem::path(info.dli_fname).parent_path();
#endif
}

std::filesystem::path FindAsset(const std::filesystem::path& relative) {
  std::vector<std::filesystem::path> roots;
  if (const char* env = std::getenv("RILLIGHT_ENHANCEMENT_DIR"))
    roots.emplace_back(env);
#ifdef RILLIGHT_ENHANCEMENT_MODEL_DIR
  roots.emplace_back(RILLIGHT_ENHANCEMENT_MODEL_DIR);
#endif
  const std::filesystem::path module = ModuleDirectory();
  if (!module.empty()) roots.push_back(module);
  for (const auto& root : roots) {
    const std::filesystem::path candidate = root / relative;
    if (std::filesystem::is_regular_file(candidate)) return candidate;
  }
  return {};
}

#if RILLIGHT_HAVE_NCNN

class RifeWarp final : public ncnn::Layer {
 public:
  int forward(const std::vector<ncnn::Mat>& bottom, std::vector<ncnn::Mat>& top,
              const ncnn::Option&) const override {
    if (bottom.size() < 2 || bottom[0].empty() || bottom[1].empty()) return -1;
    const ncnn::Mat& image = bottom[0];
    const ncnn::Mat& flow = bottom[1];
    if (image.w != flow.w || image.h != flow.h || image.c <= 0 || flow.c < 2)
      return -1;
    ncnn::Mat& out = top[0];
    out.create(image.w, image.h, image.c);
    if (out.empty()) return -100;
    const ncnn::Mat flow_x_plane = flow.channel(0);
    const ncnn::Mat flow_y_plane = flow.channel(1);
    for (int channel = 0; channel < image.c; ++channel) {
      const ncnn::Mat source = image.channel(channel);
      ncnn::Mat dest = out.channel(channel);
      for (int y = 0; y < image.h; ++y) {
        const float* flow_x = flow_x_plane.row(y);
        const float* flow_y = flow_y_plane.row(y);
        float* row = dest.row(y);
        for (int x = 0; x < image.w; ++x) {
          const float sample_x = static_cast<float>(x) + flow_x[x];
          const float sample_y = static_cast<float>(y) + flow_y[x];
          const int x0 = std::clamp(static_cast<int>(std::floor(sample_x)), 0, image.w - 1);
          const int y0 = std::clamp(static_cast<int>(std::floor(sample_y)), 0, image.h - 1);
          const int x1 = std::clamp(x0 + 1, 0, image.w - 1);
          const int y1 = std::clamp(y0 + 1, 0, image.h - 1);
          const float alpha = sample_x - std::floor(sample_x);
          const float beta = sample_y - std::floor(sample_y);
          const float v0 = source.row(y0)[x0];
          const float v1 = source.row(y0)[x1];
          const float v2 = source.row(y1)[x0];
          const float v3 = source.row(y1)[x1];
          const float top_value = v0 * (1.0f - alpha) + v1 * alpha;
          const float bottom_value = v2 * (1.0f - alpha) + v3 * alpha;
          row[x] = top_value * (1.0f - beta) + bottom_value * beta;
        }
      }
    }
    return 0;
  }
};

ncnn::Layer* CreateRifeWarp(void*) { return new RifeWarp; }

struct Nets {
  ncnn::Net rife;
  ncnn::Net super_resolution;
  bool rife_ready = false;
  bool super_ready = false;
  std::mutex mutex;
};

Nets& Models() {
  static Nets nets;
  return nets;
}

bool LoadParam(ncnn::Net* net, const std::filesystem::path& param,
               const std::filesystem::path& bin, const char* param_hash,
               const char* bin_hash) {
  if (Sha256File(param) != param_hash || Sha256File(bin) != bin_hash) return false;
  net->opt.use_vulkan_compute = false;
  net->opt.num_threads = 2;
  net->opt.lightmode = true;
  return net->load_param(param.string().c_str()) == 0 &&
         net->load_model(bin.string().c_str()) == 0;
}

void EnsureLoaded() {
  static std::once_flag once;
  std::call_once(once, [] {
    try {
      Nets& nets = Models();
      nets.rife.register_custom_layer("rife.Warp", &CreateRifeWarp);
      const std::filesystem::path rife_param = FindAsset("rife-v4.6/flownet.param");
      const std::filesystem::path rife_bin = FindAsset("rife-v4.6/flownet.bin");
      if (!rife_param.empty() && !rife_bin.empty()) {
        nets.rife_ready = LoadParam(
            &nets.rife, rife_param, rife_bin,
            "28df14d57a225725ee5386f52eba422488450d37c9f40800ed4f62e8ba846692",
            "f334ed2260149ce0188a6dcf049844e8b0cdd912e01cbcfb63553157d2508958");
      }
      const std::filesystem::path sr_param = FindAsset("realesr-general-x4v3.param");
      const std::filesystem::path sr_bin = FindAsset("realesr-general-x4v3.bin");
      if (!sr_param.empty() && !sr_bin.empty()) {
        nets.super_ready = LoadParam(
            &nets.super_resolution, sr_param, sr_bin,
            "22174924330297357434ad21ed0af7f4b820008d2a502b492754d130d4142714",
            "85ee266b632a765a725425ba6a5620c088c8aa2939a03063b2d83b3462724cc1");
      }
    } catch (const std::exception&) {
    }
  });
}

bool RunSuperResolutionTile(const float* rgb, int width, int height, int origin_x,
                            int origin_y, int tile_w, int tile_h, float ceiling,
                            std::vector<float>* full, int full_width) {
  ncnn::Mat input(tile_w, tile_h, 3);
  if (input.empty()) return false;
  for (int channel = 0; channel < 3; ++channel) {
    for (int y = 0; y < tile_h; ++y) {
      float* row = input.channel(channel).row(y);
      for (int x = 0; x < tile_w; ++x) {
        const int sx = std::clamp(origin_x + x, 0, width - 1);
        const int sy = std::clamp(origin_y + y, 0, height - 1);
        row[x] = rgb[(static_cast<size_t>(sy) * static_cast<size_t>(width) +
                      static_cast<size_t>(sx)) *
                         3u +
                     static_cast<size_t>(channel)] /
                 ceiling;
      }
    }
  }
  ncnn::Mat output;
  {
    std::lock_guard<std::mutex> lock(Models().mutex);
    ncnn::Extractor extractor = Models().super_resolution.create_extractor();
    extractor.set_light_mode(true);
    if (extractor.input("data", input) != 0 || extractor.extract("output", output) != 0)
      return false;
  }
  if (output.w != tile_w * 4 || output.h != tile_h * 4 || output.c < 3) return false;
  const int product_x0 = origin_x * 2;
  const int product_y0 = origin_y * 2;
  for (int y = 0; y < tile_h * 2; ++y) {
    for (int x = 0; x < tile_w * 2; ++x) {
      const int dest_x = product_x0 + x;
      const int dest_y = product_y0 + y;
      if (dest_x < 0 || dest_y < 0 || dest_x >= width * 2 || dest_y >= height * 2)
        continue;
      float sum[3] = {};
      for (int by = 0; by < 2; ++by) {
        for (int bx = 0; bx < 2; ++bx) {
          const int mx = x * 2 + bx;
          const int my = y * 2 + by;
          for (int channel = 0; channel < 3; ++channel) {
            const float value = output.channel(channel).row(my)[mx];
            if (!std::isfinite(value)) return false;
            sum[channel] += value;
          }
        }
      }
      float* dest = full->data() + (static_cast<size_t>(dest_y) *
                                        static_cast<size_t>(full_width) +
                                    static_cast<size_t>(dest_x)) *
                                       3u;
      for (int channel = 0; channel < 3; ++channel)
        dest[channel] = std::clamp(sum[channel] * 0.25f * ceiling, 0.0f, ceiling);
    }
  }
  return true;
}

#endif

}  // namespace

bool RifeReady() {
#if RILLIGHT_HAVE_NCNN
  try {
    EnsureLoaded();
    return Models().rife_ready;
  } catch (const std::exception&) {
    return false;
  }
#else
  return false;
#endif
}

bool ApplyRife(const std::vector<float>& prior, const std::vector<float>& current,
               int width, int height, float ceiling, std::vector<float>* midpoint) {
#if RILLIGHT_HAVE_NCNN
  if (!midpoint || width <= 0 || height <= 0 || !std::isfinite(ceiling) ||
      ceiling <= 0.0f)
    return false;
  const size_t count = static_cast<size_t>(width) * static_cast<size_t>(height) * 3u;
  if (prior.size() != count || current.size() != count || !RifeReady()) return false;
  try {
    const int padded_w = (width + 31) / 32 * 32;
    const int padded_h = (height + 31) / 32 * 32;
    ncnn::Mat in0(padded_w, padded_h, 3);
    ncnn::Mat in1(padded_w, padded_h, 3);
    ncnn::Mat timestep(padded_w, padded_h, 1);
    if (in0.empty() || in1.empty() || timestep.empty()) return false;
    timestep.fill(0.5f);
    for (int channel = 0; channel < 3; ++channel) {
      for (int y = 0; y < padded_h; ++y) {
        float* row0 = in0.channel(channel).row(y);
        float* row1 = in1.channel(channel).row(y);
        for (int x = 0; x < padded_w; ++x) {
          if (y < height && x < width) {
            const size_t index = (static_cast<size_t>(y) * static_cast<size_t>(width) +
                                  static_cast<size_t>(x)) *
                                     3u +
                                 static_cast<size_t>(channel);
            row0[x] = prior[index] / ceiling;
            row1[x] = current[index] / ceiling;
          } else {
            row0[x] = 0.0f;
            row1[x] = 0.0f;
          }
        }
      }
    }
    ncnn::Mat output;
    {
      std::lock_guard<std::mutex> lock(Models().mutex);
      ncnn::Extractor extractor = Models().rife.create_extractor();
      extractor.set_light_mode(true);
      if (extractor.input("in0", in0) != 0 || extractor.input("in1", in1) != 0 ||
          extractor.input("in2", timestep) != 0 || extractor.extract("out0", output) != 0)
        return false;
    }
    if (output.w < width || output.h < height || output.c < 3) return false;
    midpoint->assign(count, 0.0f);
    for (int channel = 0; channel < 3; ++channel) {
      for (int y = 0; y < height; ++y) {
        const float* row = output.channel(channel).row(y);
        for (int x = 0; x < width; ++x) {
          const float value = row[x] * ceiling;
          if (!std::isfinite(value)) return false;
          (*midpoint)[(static_cast<size_t>(y) * static_cast<size_t>(width) +
                       static_cast<size_t>(x)) *
                          3u +
                      static_cast<size_t>(channel)] =
              std::clamp(value, 0.0f, ceiling);
        }
      }
    }
    return true;
  } catch (const std::exception&) {
    return false;
  }
#else
  (void)prior;
  (void)current;
  (void)width;
  (void)height;
  (void)ceiling;
  (void)midpoint;
  return false;
#endif
}

bool SuperResolutionReady() {
#if RILLIGHT_HAVE_NCNN
  try {
    EnsureLoaded();
    return Models().super_ready;
  } catch (const std::exception&) {
    return false;
  }
#else
  return false;
#endif
}

bool ApplySuperResolution(std::vector<float>* rgb, std::vector<float>* alpha, int* width,
                          int* height, float ceiling) {
#if RILLIGHT_HAVE_NCNN
  if (!rgb || !alpha || !width || !height || *width <= 0 || *height <= 0 ||
      !std::isfinite(ceiling) || ceiling <= 0.0f || !SuperResolutionReady())
    return false;
  const int source_w = *width;
  const int source_h = *height;
  const size_t pixels = static_cast<size_t>(source_w) * static_cast<size_t>(source_h);
  if (rgb->size() != pixels * 3u || alpha->size() != pixels) return false;
  try {
    constexpr int kTile = 64;
    constexpr int kOverlap = 16;
    std::vector<float> scaled(
        static_cast<size_t>(source_w * 2) * static_cast<size_t>(source_h * 2) * 3u, 0.0f);
    for (int origin_y = 0; origin_y < source_h;) {
      const int tile_h = std::min(kTile, source_h - origin_y);
      for (int origin_x = 0; origin_x < source_w;) {
        const int tile_w = std::min(kTile, source_w - origin_x);
        int copy_x0 = origin_x == 0 ? 0 : kOverlap / 2;
        int copy_y0 = origin_y == 0 ? 0 : kOverlap / 2;
        int copy_x1 = origin_x + tile_w >= source_w ? tile_w : tile_w - kOverlap / 2;
        int copy_y1 = origin_y + tile_h >= source_h ? tile_h : tile_h - kOverlap / 2;
        if (copy_x1 <= copy_x0) copy_x1 = tile_w;
        if (copy_y1 <= copy_y0) copy_y1 = tile_h;
        std::vector<float> tile_rgb(static_cast<size_t>(tile_w * tile_h * 3));
        for (int y = 0; y < tile_h; ++y) {
          for (int x = 0; x < tile_w; ++x) {
            const size_t from = (static_cast<size_t>(origin_y + y) *
                                     static_cast<size_t>(source_w) +
                                 static_cast<size_t>(origin_x + x)) *
                                3u;
            const size_t to =
                (static_cast<size_t>(y) * static_cast<size_t>(tile_w) + static_cast<size_t>(x)) *
                3u;
            tile_rgb[to] = (*rgb)[from];
            tile_rgb[to + 1] = (*rgb)[from + 1];
            tile_rgb[to + 2] = (*rgb)[from + 2];
          }
        }
        std::vector<float> tile_out(static_cast<size_t>(tile_w * 2) *
                                    static_cast<size_t>(tile_h * 2) * 3u);
        if (!RunSuperResolutionTile(tile_rgb.data(), tile_w, tile_h, 0, 0, tile_w, tile_h,
                                   ceiling, &tile_out, tile_w * 2))
          return false;
        for (int y = copy_y0 * 2; y < copy_y1 * 2; ++y) {
          for (int x = copy_x0 * 2; x < copy_x1 * 2; ++x) {
            const size_t from = (static_cast<size_t>(y) * static_cast<size_t>(tile_w * 2) +
                                 static_cast<size_t>(x)) *
                                3u;
            const size_t dest_x = static_cast<size_t>(origin_x * 2 + x);
            const size_t dest_y = static_cast<size_t>(origin_y * 2 + y);
            const size_t to =
                (dest_y * static_cast<size_t>(source_w * 2) + dest_x) * 3u;
            scaled[to] = tile_out[from];
            scaled[to + 1] = tile_out[from + 1];
            scaled[to + 2] = tile_out[from + 2];
          }
        }
        origin_x += origin_x + tile_w >= source_w ? tile_w : tile_w - kOverlap;
      }
      origin_y += origin_y + tile_h >= source_h ? tile_h : tile_h - kOverlap;
    }
    std::vector<float> scaled_alpha(static_cast<size_t>(source_w * 2 * source_h * 2));
    for (int y = 0; y < source_h * 2; ++y) {
      for (int x = 0; x < source_w * 2; ++x) {
        const float sx =
            ((static_cast<float>(x) + 0.5f) * static_cast<float>(source_w) /
             static_cast<float>(source_w * 2)) -
            0.5f;
        const float sy =
            ((static_cast<float>(y) + 0.5f) * static_cast<float>(source_h) /
             static_cast<float>(source_h * 2)) -
            0.5f;
        const float cx = std::clamp(sx, 0.0f, static_cast<float>(source_w - 1));
        const float cy = std::clamp(sy, 0.0f, static_cast<float>(source_h - 1));
        const int x0 = static_cast<int>(std::floor(cx));
        const int y0 = static_cast<int>(std::floor(cy));
        const int x1 = std::min(x0 + 1, source_w - 1);
        const int y1 = std::min(y0 + 1, source_h - 1);
        const float fx = cx - static_cast<float>(x0);
        const float fy = cy - static_cast<float>(y0);
        auto at = [&](int px, int py) {
          return (*alpha)[static_cast<size_t>(py * source_w + px)];
        };
        scaled_alpha[static_cast<size_t>(y * source_w * 2 + x)] =
            (at(x0, y0) * (1.0f - fx) + at(x1, y0) * fx) * (1.0f - fy) +
            (at(x0, y1) * (1.0f - fx) + at(x1, y1) * fx) * fy;
      }
    }
    *rgb = std::move(scaled);
    *alpha = std::move(scaled_alpha);
    *width = source_w * 2;
    *height = source_h * 2;
    return true;
  } catch (const std::exception&) {
    return false;
  }
#else
  (void)rgb;
  (void)alpha;
  (void)width;
  (void)height;
  (void)ceiling;
  return false;
#endif
}

}  // namespace rillight
