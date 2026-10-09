// Differential oracle intentionally retains the scalar pass from 8447a14.
// Include the interpreter to exercise internal passes without a public test API.
#include "../core/anime4k_glsl.cpp"
#include <cassert>
#include <chrono>
#include <cstdio>

namespace rillight {
namespace {
bool ReferencePass(const Pass& pass, std::map<std::string, Plane>* planes, int output_width,
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

bool ReferenceChain(const ShaderChain& chain, Plane* main, const std::vector<float>& alpha,
              int alpha_width, int alpha_height) {
  if (!main || main->width <= 0 || main->height <= 0) return false;
  const int output_width = main->width * 2;
  const int output_height = main->height * 2;
  std::map<std::string, Plane> planes;
  planes.emplace("MAIN", *main);
  for (const Pass& pass : chain.passes) {
    if (!ReferencePass(pass, &planes, output_width, output_height)) return false;
  }
  const auto produced = planes.find("MAIN");
  if (produced == planes.end()) return false;
  *main = produced->second;
  KeepAlpha(main, alpha, alpha_width, alpha_height);
  return true;
}


Plane MakePlane(int width, int height) {
  Plane plane{width, height, {}};
  plane.rgba.resize(static_cast<size_t>(width) * height * 4);
  uint32_t random = 73;
  for (float& value : plane.rgba) {
    random = random * 1664525u + 1013904223u;
    value = static_cast<float>(random >> 8) / 16777216.0f - .25f;
  }
  return plane;
}

void CheckPasses() {
  for (const auto size : {std::pair{1, 1}, std::pair{1, 9}, std::pair{11, 1},
                           std::pair{7, 13}, std::pair{32, 19}}) {
    const Plane source = MakePlane(size.first, size.second);
    for (const int scale : {1, 2, 3}) {
      Pass pass;
      pass.save = "MAIN"; pass.width_expr = "OUTPUT.w";
      pass.height_expr = "OUTPUT.h"; pass.add_main = true;
      for (int relu : {-1, 0, 1}) {
        for (float offset : {-1.0f, 0.0f, .5f, 1.0f}) {
          Term term; term.texture = "MAIN"; term.dx = offset;
          term.dy = -offset; term.relu = relu;
          for (int i = 0; i < 16; ++i) term.matrix[i] = (i - 8) * .003f;
          pass.terms.push_back(term);
        }
      }
      Term bias; bias.bias = true; bias.bias_value[0] = .03f;
      pass.terms.insert(pass.terms.begin() + 2, bias);
      for (bool shuffle : {false, true}) {
        pass.shuffle = shuffle;
        pass.shuffle_taps = {"MAIN", "MAIN", "MAIN", "MAIN"};
        std::map<std::string, Plane> actual{{"MAIN", source}}, expected = actual;
        assert(RunPass(pass, &actual, size.first * scale, size.second * scale));
        assert(ReferencePass(pass, &expected, size.first * scale, size.second * scale));
        assert(actual.at("MAIN").rgba == expected.at("MAIN").rgba);
      }
      pass.shuffle = false;
      pass.terms[0].texture = "missing";
      std::map<std::string, Plane> unchanged{{"MAIN", source}};
      assert(!RunPass(pass, &unchanged, size.first, size.second));
      assert(unchanged.at("MAIN").rgba == source.rgba);
    }
  }
}

void CheckChains() {
  assert(Chains().ready);
  for (const auto* chain : {&Chains().light_restore, &Chains().light_upscale,
                            &Chains().strong_restore, &Chains().strong_upscale}) {
    for (const auto size : {std::pair{1, 1}, std::pair{1, 9}, std::pair{11, 1},
                             std::pair{7, 13}, std::pair{16, 10}}) {
      Plane actual = MakePlane(size.first, size.second), expected = actual;
      std::vector<float> alpha(static_cast<size_t>(size.first) * size.second);
      for (size_t i = 0; i < alpha.size(); ++i) alpha[i] = actual.rgba[i * 4 + 3];
      assert(RunChain(*chain, &actual, alpha, size.first, size.second));
      assert(ReferenceChain(*chain, &expected, alpha, size.first, size.second));
      assert(actual.width == expected.width && actual.height == expected.height);
      assert(actual.rgba == expected.rgba);
    }
  }
}

void Benchmark(bool reference) {
  assert(Chains().ready);
  const Plane source = MakePlane(320, 180);
  std::vector<float> alpha(320 * 180, 1);
  double samples[5];
  for (int i = -1; i < 5; ++i) {
    Plane frame = source;
    const auto start = std::chrono::steady_clock::now();
    const auto process = reference ? ReferenceChain : RunChain;
    assert(process(Chains().light_restore, &frame, alpha, 320, 180));
    assert(process(Chains().light_upscale, &frame, alpha, 320, 180));
    if (i >= 0) samples[i] = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - start).count();
  }
  std::sort(std::begin(samples), std::end(samples));
  std::printf("Anime4K light 320x180 -> 640x360 %s median %.3f ms\n",
              reference ? "reference" : "candidate", samples[2]);
}
}  // namespace
}  // namespace rillight

int main(int argc, char** argv) {
  if (argc > 1) {
    rillight::Benchmark(std::string(argv[1]) == "--reference");
    return 0;
  }
  rillight::CheckPasses();
  rillight::CheckChains();
  std::puts("Anime4K scalar-reference pass and pinned-chain comparisons passed");
}
