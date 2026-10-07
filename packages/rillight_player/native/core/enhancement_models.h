#ifndef RILLIGHT_ENHANCEMENT_MODELS_H_
#define RILLIGHT_ENHANCEMENT_MODELS_H_

#include <vector>

namespace rillight {

// RIFE v4.6 flownet via ncnn. False when the net or weights are unavailable.
bool RifeReady();
// prior/current are interleaved RGB in the caller's ceiling range.
bool ApplyRife(const std::vector<float>& prior, const std::vector<float>& current,
               int width, int height, float ceiling, std::vector<float>* midpoint);

// realesr-general-x4v3 via ncnn, then a 2x2 box downsample to the product 2x.
bool SuperResolutionReady();
bool ApplySuperResolution(std::vector<float>* rgb, std::vector<float>* alpha,
                          int* width, int* height, float ceiling);

}  // namespace rillight

#endif
