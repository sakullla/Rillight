#ifndef RILLIGHT_DECODER_PROBE_H_
#define RILLIGHT_DECODER_PROBE_H_

#ifdef __cplusplus
extern "C" {
#endif

/* 1 when the linked FFmpeg build can decode [name], otherwise 0. */
int rillight_core_has_decoder(const char *name);

#ifdef __cplusplus
}
#endif

#endif
