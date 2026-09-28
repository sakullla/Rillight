#include "decoder_probe.h"

#include <libavcodec/avcodec.h>

#if defined(_WIN32)
#define RILLIGHT_DECODER_API __declspec(dllexport)
#else
#define RILLIGHT_DECODER_API __attribute__((visibility("default")))
#endif

extern "C" {

RILLIGHT_DECODER_API int rillight_core_has_decoder(const char *name) {
  if (name == nullptr || name[0] == '\0') return 0;
  return avcodec_find_decoder_by_name(name) != nullptr ? 1 : 0;
}

}
