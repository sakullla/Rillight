#include "enhancement_assets.h"
#include "anime4k_glsl.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace rillight {
namespace {

struct Plane {
  int width = 0;
  int height = 0;
  std::vector<float> rgba;
};

struct Term {
  float matrix[16] = {};
  std::string texture;
  int relu = 0;
  float dx = 0;
  float dy = 0;
  bool bias = false;
  float bias_value[4] = {};
};

struct Pass {
  std::string save;
  std::string width_expr;
  std::string height_expr;
  std::string when_expr;
  bool shuffle = false;
  bool add_main = false;
  std::vector<Term> terms;
  std::vector<std::string> shuffle_taps;
};

struct ShaderChain {
  std::vector<Pass> passes;
};

struct Vec4 {
  float value[4] = {};
};

constexpr char kRestoreM[] = "Anime4K_Restore_CNN_M.glsl";
constexpr char kUpscaleM[] = "Anime4K_Upscale_CNN_x2_M.glsl";
constexpr char kRestoreVl[] = "Anime4K_Restore_CNN_VL.glsl";
constexpr char kUpscaleVl[] = "Anime4K_Upscale_CNN_x2_VL.glsl";
constexpr char kHashRestoreM[] =
    "dd515c307d97d8e5c809f263dd94174cc5667b8c1299082cdff14e6ddfc8d4bc";
constexpr char kHashUpscaleM[] =
    "249dc3be467f556ed3361deea79f42bac1ae57456c22588c2cc3c2ee8808909c";
constexpr char kHashRestoreVl[] =
    "da18324507c31947943a4401ddcaea669a027705c5d8f4675aeca8a671c2eea7";
constexpr char kHashUpscaleVl[] =
    "ff9028a58aac9ad470ecbe379c1accf72443b348fa59eac7af1f091e333c733e";

uint32_t Rotr(uint32_t value, uint32_t bits) {
  return (value >> bits) | (value << (32 - bits));
}

std::string Sha256(const std::string& bytes) {
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
  std::string message = bytes;
  const uint64_t bits = static_cast<uint64_t>(bytes.size()) * 8u;
  message.push_back(static_cast<char>(0x80));
  while ((message.size() % 64) != 56) message.push_back(0);
  for (int shift = 7; shift >= 0; --shift)
    message.push_back(static_cast<char>((bits >> (shift * 8)) & 0xffu));
  for (size_t offset = 0; offset < message.size(); offset += 64) {
    uint32_t word[64];
    for (int index = 0; index < 16; ++index) {
      const unsigned char* block = reinterpret_cast<const unsigned char*>(
          message.data() + offset + static_cast<size_t>(index) * 4u);
      word[index] = (static_cast<uint32_t>(block[0]) << 24) |
                    (static_cast<uint32_t>(block[1]) << 16) |
                    (static_cast<uint32_t>(block[2]) << 8) |
                    static_cast<uint32_t>(block[3]);
    }
    for (int index = 16; index < 64; ++index) {
      const uint32_t small = Rotr(word[index - 15], 7) ^
                             Rotr(word[index - 15], 18) ^ (word[index - 15] >> 3);
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


std::vector<std::filesystem::path> ShaderRoots() {
  std::vector<std::filesystem::path> roots;
  const auto override_dir = EnhancementOverrideDirectory();
  if (!override_dir.empty()) roots.push_back(override_dir);
#ifdef RILLIGHT_ANIME4K_DIR
  roots.emplace_back(RILLIGHT_ANIME4K_DIR);
#endif
  const std::filesystem::path module = EnhancementModuleDirectory();
  if (!module.empty()) {
    roots.push_back(module / "shaders" / "anime4k");
    roots.push_back(module);
  }
  return roots;
}

bool ReadFile(const std::filesystem::path& path, std::string* text) {
  std::ifstream input(path, std::ios::binary);
  if (!input) return false;
  std::ostringstream buffer;
  buffer << input.rdbuf();
  *text = buffer.str();
  return !text->empty();
}

std::filesystem::path FindShader(const char* name) {
  for (const auto& root : ShaderRoots()) {
    const std::filesystem::path candidates[] = {
        root / name, root / "shaders" / "anime4k" / name, root / "anime4k" / name};
    for (const auto& candidate : candidates) {
      if (std::filesystem::is_regular_file(candidate)) return candidate;
    }
  }
  return {};
}

bool StartsWith(const std::string& text, const char* prefix) {
  const size_t length = std::strlen(prefix);
  return text.size() >= length && text.compare(0, length, prefix) == 0;
}

std::string Trim(std::string text) {
  while (!text.empty() &&
         (text.back() == '\r' || text.back() == ' ' || text.back() == '\t'))
    text.pop_back();
  size_t start = 0;
  while (start < text.size() && (text[start] == ' ' || text[start] == '\t')) ++start;
  return text.substr(start);
}

std::vector<std::string> SplitLines(const std::string& text) {
  std::vector<std::string> lines;
  std::string current;
  for (char ch : text) {
    if (ch == '\n') {
      lines.push_back(Trim(current));
      current.clear();
    } else {
      current.push_back(ch);
    }
  }
  if (!current.empty()) lines.push_back(Trim(current));
  return lines;
}

bool ParseFloats(const std::string& text, float* values, int count) {
  int filled = 0;
  const char* cursor = text.c_str();
  while (filled < count && *cursor) {
    char* end = nullptr;
    values[filled] = std::strtof(cursor, &end);
    if (end == cursor) return false;
    ++filled;
    cursor = end;
    if (*cursor == ',') ++cursor;
  }
  return filled == count;
}

std::string TextureNameBefore(const std::string& line, const char* key) {
  const size_t mark = line.find(key);
  if (mark == std::string::npos || mark == 0) return {};
  size_t begin = mark;
  while (begin > 0 &&
         (std::isalnum(static_cast<unsigned char>(line[begin - 1])) ||
          line[begin - 1] == '_'))
    --begin;
  return line.substr(begin, mark - begin);
}

struct SampleRef {
  std::string texture;
  int relu = 0;
};

bool ParseDefines(const std::vector<std::string>& lines,
                  std::map<std::string, SampleRef>* samples) {
  for (const std::string& line : lines) {
    if (!StartsWith(line, "#define ")) continue;
    const bool negative = line.find("max(-(") != std::string::npos;
    const bool positive = line.find("max((") != std::string::npos;
    const bool offset = line.find("_texOff") != std::string::npos;
    SampleRef sample;
    sample.relu = negative ? -1 : positive ? 1 : 0;
    sample.texture = TextureNameBefore(line, offset ? "_texOff" : "_tex(");
    if (sample.texture.empty()) return false;
    const size_t go = line.find("go_");
    const size_t center = line.find("g_");
    std::string key;
    if (go != std::string::npos && (center == std::string::npos || go <= center)) {
      const size_t end = line.find('(', go);
      if (end == std::string::npos) return false;
      key = line.substr(go, end - go);
    } else if (center != std::string::npos) {
      size_t end = center + 2;
      while (end < line.size() && std::isdigit(static_cast<unsigned char>(line[end])))
        ++end;
      key = line.substr(center, end - center);
    } else {
      return false;
    }
    (*samples)[key] = std::move(sample);
  }
  return true;
}

bool ParseTerm(const std::string& line, const std::map<std::string, SampleRef>& samples,
               Term* term) {
  if (StartsWith(line, "result += vec4(")) {
    const size_t open = line.find('(');
    const size_t close = line.find(')', open);
    if (close == std::string::npos) return false;
    term->bias = true;
    return ParseFloats(line.substr(open + 1, close - open - 1), term->bias_value, 4);
  }
  const size_t mat = line.find("mat4(");
  if (mat == std::string::npos) return false;
  const size_t close = line.find(')', mat);
  if (close == std::string::npos) return false;
  if (!ParseFloats(line.substr(mat + 5, close - mat - 5), term->matrix, 16))
    return false;
  const size_t go = line.find("go_", close);
  const size_t center = line.find("g_", close);
  std::string key;
  if (go != std::string::npos) {
    const size_t open = line.find('(', go);
    const size_t comma = line.find(',', open);
    const size_t end = line.find(')', comma);
    if (end == std::string::npos) return false;
    key = line.substr(go, open - go);
    term->dx = std::strtof(line.c_str() + open + 1, nullptr);
    term->dy = std::strtof(line.c_str() + comma + 1, nullptr);
  } else if (center != std::string::npos) {
    size_t end = center + 2;
    while (end < line.size() && std::isdigit(static_cast<unsigned char>(line[end])))
      ++end;
    key = line.substr(center, end - center);
  } else {
    return false;
  }
  const auto found = samples.find(key);
  if (found == samples.end()) return false;
  term->texture = found->second.texture;
  term->relu = found->second.relu;
  return true;
}

std::vector<std::string> ParseShuffleTaps(const std::string& chunk) {
  std::vector<std::string> taps;
  size_t cursor = 0;
  while ((cursor = chunk.find("float c", cursor)) != std::string::npos) {
    const size_t eq = chunk.find('=', cursor);
    const size_t semi = chunk.find(';', eq);
    if (eq == std::string::npos || semi == std::string::npos) break;
    const std::string rhs = Trim(chunk.substr(eq + 1, semi - eq - 1));
    if (rhs.find("_tex") != std::string::npos) taps.push_back(TextureNameBefore(rhs, "_tex"));
    else if (!taps.empty()) taps.push_back(taps.back());
    cursor = semi + 1;
  }
  return taps;
}

bool ParsePass(const std::string& chunk, Pass* pass) {
  const auto lines = SplitLines(chunk);
  std::map<std::string, SampleRef> samples;
  if (!ParseDefines(lines, &samples)) return false;
  bool in_hook = false;
  for (const std::string& line : lines) {
    if (StartsWith(line, "//!SAVE ")) {
      pass->save = Trim(line.substr(8));
      continue;
    }
    if (StartsWith(line, "//!WIDTH ")) {
      pass->width_expr = Trim(line.substr(9));
      continue;
    }
    if (StartsWith(line, "//!HEIGHT ")) {
      pass->height_expr = Trim(line.substr(10));
      continue;
    }
    if (StartsWith(line, "//!WHEN ")) {
      pass->when_expr = Trim(line.substr(8));
      continue;
    }
    if (StartsWith(line, "//")) continue;
    if (StartsWith(line, "vec4 hook()")) {
      in_hook = true;
      continue;
    }
    if (!in_hook || line.empty() || line == "{" || line == "}") continue;
    if (StartsWith(line, "return")) {
      pass->add_main = line.find("MAIN_tex") != std::string::npos;
      continue;
    }
    if (chunk.find("fract(") != std::string::npos) continue;
    Term term;
    if (!ParseTerm(line, samples, &term)) return false;
    pass->terms.push_back(std::move(term));
  }
  pass->shuffle = chunk.find("fract(") != std::string::npos;
  if (pass->shuffle) {
    pass->shuffle_taps = ParseShuffleTaps(chunk);
    pass->add_main = true;
    pass->terms.clear();
    if (pass->shuffle_taps.size() != 4) return false;
    for (const std::string& tap : pass->shuffle_taps) {
      if (tap.empty()) return false;
    }
  }
  return !pass->save.empty() && !pass->width_expr.empty() &&
         !pass->height_expr.empty() && (pass->shuffle || !pass->terms.empty());
}

bool ParseShader(const std::string& text, ShaderChain* chain) {
  size_t cursor = 0;
  while ((cursor = text.find("//!HOOK", cursor)) != std::string::npos) {
    const size_t next = text.find("//!HOOK", cursor + 7);
    Pass pass;
    const std::string chunk = text.substr(
        cursor, next == std::string::npos ? std::string::npos : next - cursor);
    if (!ParsePass(chunk, &pass)) return false;
    chain->passes.push_back(std::move(pass));
    if (next == std::string::npos) break;
    cursor = next;
  }
  return !chain->passes.empty();
}

bool EvalRpn(const std::string& expr, const std::map<std::string, Plane>& planes,
             int output_width, int output_height, double* value) {
  if (expr.empty()) {
    *value = 1;
    return true;
  }
  std::vector<double> stack;
  std::string token;
  auto flush = [&]() {
    if (token.empty()) return true;
    if (token == "+" || token == "-" || token == "*" || token == "/" || token == ">" ||
        token == "<") {
      if (stack.size() < 2) return false;
      const double right = stack.back();
      stack.pop_back();
      const double left = stack.back();
      stack.pop_back();
      double result = 0;
      if (token == "+") result = left + right;
      else if (token == "-") result = left - right;
      else if (token == "*") result = left * right;
      else if (token == "/") result = right == 0.0 ? 0.0 : left / right;
      else if (token == ">") result = left > right ? 1.0 : 0.0;
      else result = left < right ? 1.0 : 0.0;
      stack.push_back(result);
    } else {
      const size_t dot = token.rfind('.');
      if (dot != std::string::npos && dot + 2 == token.size() &&
          (token.back() == 'w' || token.back() == 'h')) {
        const std::string name = token.substr(0, dot);
        const bool width = token.back() == 'w';
        if (name == "OUTPUT") {
          stack.push_back(width ? output_width : output_height);
        } else {
          const auto found = planes.find(name);
          if (found == planes.end()) return false;
          stack.push_back(width ? found->second.width : found->second.height);
        }
      } else {
        char* end = nullptr;
        const double number = std::strtod(token.c_str(), &end);
        if (end == token.c_str()) return false;
        stack.push_back(number);
      }
    }
    token.clear();
    return true;
  };
  for (char ch : expr) {
    if (ch == ' ') {
      if (!flush()) return false;
    } else {
      token.push_back(ch);
    }
  }
  if (!flush() || stack.size() != 1) return false;
  *value = stack.back();
  return std::isfinite(*value);
}

Vec4 SamplePlane(const Plane& plane, float pixel_x, float pixel_y) {
  const float x = std::clamp(pixel_x, 0.0f, static_cast<float>(plane.width - 1));
  const float y = std::clamp(pixel_y, 0.0f, static_cast<float>(plane.height - 1));
  const int x0 = static_cast<int>(std::floor(x));
  const int y0 = static_cast<int>(std::floor(y));
  const int x1 = std::min(x0 + 1, plane.width - 1);
  const int y1 = std::min(y0 + 1, plane.height - 1);
  const float fx = x - static_cast<float>(x0);
  const float fy = y - static_cast<float>(y0);
  auto at = [&](int sx, int sy, int channel) {
    return plane.rgba[(static_cast<size_t>(sy) * static_cast<size_t>(plane.width) +
                       static_cast<size_t>(sx)) *
                          4u +
                      static_cast<size_t>(channel)];
  };
  Vec4 result;
  for (int channel = 0; channel < 4; ++channel) {
    const float top = at(x0, y0, channel) * (1.0f - fx) + at(x1, y0, channel) * fx;
    const float bottom =
        at(x0, y1, channel) * (1.0f - fx) + at(x1, y1, channel) * fx;
    result.value[channel] = top * (1.0f - fy) + bottom * fy;
  }
  return result;
}

Vec4 SampleNormalized(const Plane& plane, float nx, float ny) {
  return SamplePlane(plane, nx * static_cast<float>(plane.width) - 0.5f,
                     ny * static_cast<float>(plane.height) - 0.5f);
}

float ShuffleChannel(const Plane& plane, int out_width, int out_height, int x, int y) {
  const float pos_x = (static_cast<float>(x) + 0.5f) / static_cast<float>(out_width);
  const float pos_y = (static_cast<float>(y) + 0.5f) / static_cast<float>(out_height);
  const float scaled_x = pos_x * static_cast<float>(plane.width);
  const float scaled_y = pos_y * static_cast<float>(plane.height);
  const float fract_x = scaled_x - std::floor(scaled_x);
  const float fract_y = scaled_y - std::floor(scaled_y);
  const int index_x = std::clamp(static_cast<int>(fract_x * 2.0f), 0, 1);
  const int index_y = std::clamp(static_cast<int>(fract_y * 2.0f), 0, 1);
  const float sample_x = (0.5f - fract_x) / static_cast<float>(plane.width) + pos_x;
  const float sample_y = (0.5f - fract_y) / static_cast<float>(plane.height) + pos_y;
  return SampleNormalized(plane, sample_x, sample_y).value[index_y * 2 + index_x];
}

bool RunPass(const Pass& pass, std::map<std::string, Plane>* planes, int output_width,
             int output_height) {
  double when = 1;
  if (!EvalRpn(pass.when_expr, *planes, output_width, output_height, &when))
    return false;
  if (when <= 0) return true;
  double width_value = 0;
  double height_value = 0;
  if (!EvalRpn(pass.width_expr, *planes, output_width, output_height, &width_value) ||
      !EvalRpn(pass.height_expr, *planes, output_width, output_height, &height_value))
    return false;
  const int width = static_cast<int>(std::lround(width_value));
  const int height = static_cast<int>(std::lround(height_value));
  if (width <= 0 || height <= 0 || width > 8192 || height > 8192) return false;
  const auto main = planes->find("MAIN");
  if (main == planes->end()) return false;
  Plane produced;
  produced.width = width;
  produced.height = height;
  produced.rgba.assign(static_cast<size_t>(width) * static_cast<size_t>(height) * 4u,
                       0.0f);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      Vec4 result;
      if (pass.shuffle) {
        for (int channel = 0; channel < 4; ++channel) {
          const auto source =
              planes->find(pass.shuffle_taps[static_cast<size_t>(channel)]);
          if (source == planes->end()) return false;
          result.value[channel] =
              ShuffleChannel(source->second, width, height, x, y);
        }
      } else {
        for (const Term& term : pass.terms) {
          if (term.bias) {
            for (int channel = 0; channel < 4; ++channel)
              result.value[channel] += term.bias_value[channel];
            continue;
          }
          const auto texture = planes->find(term.texture);
          if (texture == planes->end() || texture->second.width <= 0) return false;
          const float nx = (static_cast<float>(x) + 0.5f) / static_cast<float>(width) +
                           term.dx / static_cast<float>(texture->second.width);
          const float ny = (static_cast<float>(y) + 0.5f) / static_cast<float>(height) +
                           term.dy / static_cast<float>(texture->second.height);
          Vec4 sample = SampleNormalized(texture->second, nx, ny);
          if (term.relu > 0) {
            for (float& channel : sample.value) channel = std::max(channel, 0.0f);
          } else if (term.relu < 0) {
            for (float& channel : sample.value) channel = std::max(-channel, 0.0f);
          }
          for (int column = 0; column < 4; ++column) {
            for (int row = 0; row < 4; ++row)
              result.value[row] += term.matrix[column * 4 + row] * sample.value[column];
          }
        }
      }
      if (pass.add_main) {
        const Vec4 base = SampleNormalized(
            main->second, (static_cast<float>(x) + 0.5f) / static_cast<float>(width),
            (static_cast<float>(y) + 0.5f) / static_cast<float>(height));
        for (int channel = 0; channel < 4; ++channel) result.value[channel] += base.value[channel];
      }
      float* dest = produced.rgba.data() +
                    (static_cast<size_t>(y) * static_cast<size_t>(width) +
                     static_cast<size_t>(x)) *
                        4u;
      for (float channel : result.value) {
        if (!std::isfinite(channel)) return false;
      }
      std::memcpy(dest, result.value, sizeof(result.value));
    }
  }
  (*planes)[pass.save] = std::move(produced);
  return true;
}

void KeepAlpha(Plane* plane, const std::vector<float>& alpha, int source_width,
               int source_height) {
  for (int y = 0; y < plane->height; ++y) {
    for (int x = 0; x < plane->width; ++x) {
      const float sx =
          ((static_cast<float>(x) + 0.5f) * static_cast<float>(source_width) /
           static_cast<float>(plane->width)) -
          0.5f;
      const float sy =
          ((static_cast<float>(y) + 0.5f) * static_cast<float>(source_height) /
           static_cast<float>(plane->height)) -
          0.5f;
      const float cx = std::clamp(sx, 0.0f, static_cast<float>(source_width - 1));
      const float cy = std::clamp(sy, 0.0f, static_cast<float>(source_height - 1));
      const int x0 = static_cast<int>(std::floor(cx));
      const int y0 = static_cast<int>(std::floor(cy));
      const int x1 = std::min(x0 + 1, source_width - 1);
      const int y1 = std::min(y0 + 1, source_height - 1);
      const float fx = cx - static_cast<float>(x0);
      const float fy = cy - static_cast<float>(y0);
      auto at = [&](int px, int py) {
        return alpha[static_cast<size_t>(py * source_width + px)];
      };
      const float top = at(x0, y0) * (1.0f - fx) + at(x1, y0) * fx;
      const float bottom = at(x0, y1) * (1.0f - fx) + at(x1, y1) * fx;
      plane->rgba[(static_cast<size_t>(y) * static_cast<size_t>(plane->width) +
                   static_cast<size_t>(x)) *
                      4u +
                  3u] = top * (1.0f - fy) + bottom * fy;
    }
  }
}

bool RunChain(const ShaderChain& chain, Plane* main, const std::vector<float>& alpha,
              int alpha_width, int alpha_height) {
  if (!main || main->width <= 0 || main->height <= 0) return false;
  const int output_width = main->width * 2;
  const int output_height = main->height * 2;
  std::map<std::string, Plane> planes;
  planes.emplace("MAIN", *main);
  for (const Pass& pass : chain.passes) {
    if (!RunPass(pass, &planes, output_width, output_height)) return false;
  }
  const auto produced = planes.find("MAIN");
  if (produced == planes.end()) return false;
  *main = produced->second;
  KeepAlpha(main, alpha, alpha_width, alpha_height);
  return true;
}

struct LoadedChains {
  ShaderChain light_restore;
  ShaderChain light_upscale;
  ShaderChain strong_restore;
  ShaderChain strong_upscale;
  bool ready = false;
};

LoadedChains& Chains() {
  static LoadedChains loaded;
  static std::once_flag once;
  std::call_once(once, [] {
    try {
      const struct Item {
        const char* name;
        const char* hash;
        ShaderChain* chain;
      } items[] = {
          {kRestoreM, kHashRestoreM, &loaded.light_restore},
          {kUpscaleM, kHashUpscaleM, &loaded.light_upscale},
          {kRestoreVl, kHashRestoreVl, &loaded.strong_restore},
          {kUpscaleVl, kHashUpscaleVl, &loaded.strong_upscale},
      };
      for (const Item& item : items) {
        std::string text;
        const std::filesystem::path path = FindShader(item.name);
        if (path.empty() || !ReadFile(path, &text) || Sha256(text) != item.hash ||
            !ParseShader(text, item.chain))
          return;
      }
      loaded.ready = true;
    } catch (const std::exception&) {
      loaded.ready = false;
    }
  });
  return loaded;
}

}  // namespace

bool Anime4kShadersReady() {
  try {
    return Chains().ready;
  } catch (const std::exception&) {
    return false;
  }
}

bool ApplyAnime4k(std::vector<float>* rgb, std::vector<float>* alpha, int* width,
                  int* height, int level, float ceiling) {
  if (!rgb || !alpha || !width || !height || (*width) <= 0 || (*height) <= 0 ||
      (level != 1 && level != 2) || !std::isfinite(ceiling) || ceiling <= 0.0f)
    return false;
  const size_t pixels = static_cast<size_t>(*width) * static_cast<size_t>(*height);
  if (rgb->size() != pixels * 3u || alpha->size() != pixels || !Chains().ready)
    return false;
  try {
    Plane main;
    main.width = *width;
    main.height = *height;
    main.rgba.assign(pixels * 4u, 0.0f);
    for (size_t index = 0; index < pixels; ++index) {
      main.rgba[index * 4u] = (*rgb)[index * 3u] / ceiling;
      main.rgba[index * 4u + 1u] = (*rgb)[index * 3u + 1u] / ceiling;
      main.rgba[index * 4u + 2u] = (*rgb)[index * 3u + 2u] / ceiling;
      main.rgba[index * 4u + 3u] = (*alpha)[index];
    }
    const std::vector<float> source_alpha = *alpha;
    const int source_width = *width;
    const int source_height = *height;
    const LoadedChains& loaded = Chains();
    const ShaderChain& restore = level == 1 ? loaded.light_restore : loaded.strong_restore;
    const ShaderChain& upscale = level == 1 ? loaded.light_upscale : loaded.strong_upscale;
    if (!RunChain(restore, &main, source_alpha, source_width, source_height))
      return false;
    std::vector<float> restored_alpha(static_cast<size_t>(main.width * main.height));
    for (int index = 0; index < main.width * main.height; ++index)
      restored_alpha[static_cast<size_t>(index)] =
          main.rgba[static_cast<size_t>(index) * 4u + 3u];
    const int restored_width = main.width;
    const int restored_height = main.height;
    if (!RunChain(upscale, &main, restored_alpha, restored_width, restored_height))
      return false;
    if (main.width != source_width * 2 || main.height != source_height * 2)
      return false;
    const size_t out_pixels =
        static_cast<size_t>(main.width) * static_cast<size_t>(main.height);
    rgb->resize(out_pixels * 3u);
    alpha->resize(out_pixels);
    for (size_t index = 0; index < out_pixels; ++index) {
      for (int channel = 0; channel < 3; ++channel) {
        const float value = main.rgba[index * 4u + static_cast<size_t>(channel)] * ceiling;
        if (!std::isfinite(value)) return false;
        (*rgb)[index * 3u + static_cast<size_t>(channel)] = value;
      }
      (*alpha)[index] = main.rgba[index * 4u + 3u];
    }
    *width = main.width;
    *height = main.height;
    return true;
  } catch (const std::exception&) {
    return false;
  }
}

}  // namespace rillight
