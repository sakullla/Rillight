#include "decoder_probe.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/codec_desc.h>
}

#if defined(_WIN32)
#define RILLIGHT_DECODER_API __declspec(dllexport)
#else
#define RILLIGHT_DECODER_API __attribute__((visibility("default")))
#endif

extern "C" {

RILLIGHT_DECODER_API int rillight_core_has_decoder(const char *name) {
  if (name == nullptr || name[0] == '\0') return 0;
  if (avcodec_find_decoder_by_name(name)) return 1;
  // Container codec names (for example "mp3") can differ from the selected
  // decoder's implementation name ("mp3float"). Probe both forms.
  const AVCodecDescriptor* codec = avcodec_descriptor_get_by_name(name);
  return codec && avcodec_find_decoder(codec->id) ? 1 : 0;
}

}
