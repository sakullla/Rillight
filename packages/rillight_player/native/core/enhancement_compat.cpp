// Removed feature: retain ABI 10 symbols for older clients, without models,
// pixel processing, allocation, decoder changes, or background work.
#include "rillight_core.h"

extern "C" {
int rillight_enhancement_model_ready(int) { return 0; }
int rillight_enhancement_resolve(const RillightCoreEnhancementRequest*,
    const RillightCoreEnhancementFacts*, const RillightCoreEnhancementLoad*,
    RillightCoreEnhancementStatus*) { return -1; }
int rillight_enhancement_process_rgba(const RillightCoreEnhancementRequest*,
    const RillightCoreEnhancementFacts*, const RillightCoreEnhancementLoad*,
    const uint8_t*, int, int, int, const uint8_t*, int, uint8_t*, int,
    int*, int*, uint8_t*, int, int*) { return -1; }
}
