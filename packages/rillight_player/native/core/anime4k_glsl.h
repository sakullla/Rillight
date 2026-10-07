#ifndef RILLIGHT_ANIME4K_GLSL_H_
#define RILLIGHT_ANIME4K_GLSL_H_

#include <vector>

namespace rillight {

// Upstream Anime4K v4.0.1 Mode A GLSL, executed on the CPU.
// level 1 is the Fast (M) 2x chain. level 2 is the HQ (VL) 2x chain.
bool Anime4kShadersReady();
bool ApplyAnime4k(std::vector<float>* rgb, std::vector<float>* alpha, int* width,
                  int* height, int level, float ceiling);

}  // namespace rillight

#endif
