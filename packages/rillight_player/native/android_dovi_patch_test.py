"""Run the exact locked patch helpers with controlled codec output and buffers.

These checks cover RPU association/lifetime and P010 bounds. They do not
establish real RPU parsing, device color output, HDR or decoding performance.
"""

from pathlib import Path
import os
import shutil
import subprocess
import unittest


NATIVE = Path(__file__).resolve().parent
PATCH = NATIVE / "patches/ffmpeg-android-dovi-rpu.patch"
ADDED = "\n".join(line[1:] for line in PATCH.read_text().splitlines()
                  if line.startswith("+") and not line.startswith("+++"))


class AndroidDoviPatchTest(unittest.TestCase):
    def compile_run(self, name, source):
        compiler = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc")
        if not compiler and Path("C:/msys64/mingw64/bin/gcc.exe").is_file():
            compiler = "C:/msys64/mingw64/bin/gcc.exe"
        if not compiler:
            self.skipTest("C compiler unavailable; native helper checks unverified")
        directory = NATIVE.parents[2] / "build/android-dovi-patch-tests"
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / (name + ".c")
        executable = directory / (name + (".exe" if os.name == "nt" else ""))
        path.write_text(source, encoding="utf-8", newline="\n")
        environment = dict(os.environ)
        environment["PATH"] = str(Path(compiler).resolve().parent) + os.pathsep + environment.get("PATH", "")
        subprocess.run([compiler, "-std=c17", "-Wall", "-Wextra", "-Werror",
                        "-Wno-sign-compare", str(path), "-o", str(executable)],
                       env=environment, check=True)
        subprocess.run([str(executable)], env=environment, check=True)

    def test_p010_crop_padding_and_truncation(self):
        helper = ADDED.split("static int mediacodec_copy_p010(", 1)[1]
        helper = "static int mediacodec_copy_p010(" + helper.split("\n}\n", 1)[0] + "\n}\n"
        self.compile_run("p010", r'''
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <assert.h>
#define AVERROR_INVALIDDATA -1
typedef struct { int width, height; } AVCodecContext;
typedef struct { int stride, slice_height, crop_left, crop_top, width; } MediaCodecDecContext;
typedef struct { int offset, size; } FFAMediaCodecBufferInfo;
typedef struct { uint8_t *data[2]; int linesize[2]; } AVFrame;
''' + helper + r'''
int main(void) {
    uint8_t source[224], y[32], uv[16];
    for (int i = 0; i < 224; i++) source[i] = i;
    memset(y, 0xa5, sizeof(y)); memset(uv, 0xa5, sizeof(uv));
    AVCodecContext codec = {4, 2};
    MediaCodecDecContext layout = {16, 8, 2, 2, 8};
    FFAMediaCodecBufferInfo info = {8, 192};
    AVFrame frame = {{y, uv}, {16, 16}};
    assert(mediacodec_copy_p010(&codec, &layout, source, sizeof(source), &info, &frame) == 0);
    assert(memcmp(y, source + 44, 8) == 0);
    assert(memcmp(y + 16, source + 60, 8) == 0);
    assert(memcmp(uv, source + 156, 8) == 0);
    assert(y[8] == 0xa5 && uv[8] == 0xa5); // Copy visible pixels, never padding.
    info.size = 155; // Last chroma byte lies outside reported payload.
    assert(mediacodec_copy_p010(&codec, &layout, source, sizeof(source), &info, &frame) < 0);
    info.size = 192; info.offset = -1;
    assert(mediacodec_copy_p010(&codec, &layout, source, sizeof(source), &info, &frame) < 0);
    info.offset = 40;
    assert(mediacodec_copy_p010(&codec, &layout, source, sizeof(source), &info, &frame) < 0);
    info.offset = 8; layout.crop_left = 1;
    assert(mediacodec_copy_p010(&codec, &layout, source, sizeof(source), &info, &frame) < 0);
    layout.crop_left = 6;
    assert(mediacodec_copy_p010(&codec, &layout, source, sizeof(source), &info, &frame) < 0);
    layout.crop_left = 2; layout.stride = 8;
    assert(mediacodec_copy_p010(&codec, &layout, source, sizeof(source), &info, &frame) < 0);
    layout.stride = 16; layout.crop_top = 8;
    assert(mediacodec_copy_p010(&codec, &layout, source, sizeof(source), &info, &frame) < 0);
    layout.crop_top = 2; frame.linesize[1] = 7;
    assert(mediacodec_copy_p010(&codec, &layout, source, sizeof(source), &info, &frame) < 0);
    return 0;
}
''')

    def test_rpu_reordering_seek_reset_and_bounds(self):
        helper = "static void mediacodec_dovi_reset" + ADDED.split(
            "static void mediacodec_dovi_reset", 1)[1].split("#else", 1)[0]
        self.compile_run("rpu", r'''
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <errno.h>
#define MC_DOVI_MAX_PENDING 128
#define MC_DOVI_MAX_BYTES (4 * 1024 * 1024)
#define AVERROR(e) (-(e))
#define AVERROR_INVALIDDATA -999
#define AV_NOPTS_VALUE INT64_MIN
#define AV_CODEC_ID_HEVC 1
#define AV_PIX_FMT_P010LE 2
#define AV_FRAME_DATA_DOVI_METADATA 3
typedef struct { int num, den; } AVRational;
#define AV_TIME_BASE_Q ((AVRational){1, 1000000})
typedef struct { int marker; } AVDOVIMetadata;
typedef struct { int marker; } DOVIContext;
typedef struct { int nuh_layer_id, type, size; const uint8_t *data; } H2645NAL;
typedef struct { int nb_nals; H2645NAL nals[2]; } H2645Packet;
typedef struct { int64_t pts_us; uint8_t *metadata; int size; } MediaCodecDoviFrame;
typedef struct { uint8_t *data; } AVFrameSideData;
typedef struct { int64_t pts; int format, color_range, color_primaries; AVFrameSideData side; } AVFrame;
typedef struct { int64_t pts; uint8_t *data; int size; } AVPacket;
typedef struct { int64_t discard_before_us; } MediaCodecDecContext;
typedef struct { MediaCodecDecContext *ctx; int export_dovi; int64_t discard_before_us; DOVIContext dovi; H2645Packet dovi_nals;
                 MediaCodecDoviFrame dovi_frames[128]; int dovi_count, dovi_bytes; } MediaCodecH264DecContext;
typedef struct { void *priv_data; AVRational pkt_timebase; int err_recognition; } AVCodecContext;
#define AVCOL_RANGE_JPEG 2
#define AVCOL_PRI_BT2020 9
static int alive;
static void av_free(void *p) { if (p) { alive--; free(p); } }
static int64_t av_rescale_q(int64_t t, AVRational a, AVRational b) {
    return t * a.num * b.den / (a.den * b.num);
}
static void ff_dovi_ctx_flush(DOVIContext *c) { c->marker = 0; }
static int ff_h2645_packet_split(H2645Packet *p, const uint8_t *data, int size,
                                 void *ctx, int length, int codec, int flags) {
    (void)ctx; (void)length; (void)codec; (void)flags;
    p->nb_nals = 2;
    p->nals[0] = (H2645NAL){0, 1, size, data};
    p->nals[1] = (H2645NAL){0, 62, size, data};
    return 0;
}
static int ff_dovi_rpu_parse(DOVIContext *c, const uint8_t *data, size_t size, int error) {
    (void)size; (void)error; c->marker = *data; return 0;
}
static int ff_dovi_get_metadata(DOVIContext *c, AVDOVIMetadata **out) {
    *out = malloc(sizeof(**out)); alive++;
    (*out)->marker = c->marker; return sizeof(**out);
}
static int64_t output_pts;
static int output_format = AV_PIX_FMT_P010LE;
static int ff_mediacodec_dec_receive(AVCodecContext *c, void *ctx, AVFrame *f, int wait) {
    (void)c; (void)ctx; (void)wait; f->pts = output_pts; f->format = output_format; return 0;
}
static AVFrameSideData *av_frame_new_side_data(AVFrame *f, int type, int size) {
    (void)type; f->side.data = malloc(size); alive++; return &f->side;
}
static void av_frame_unref(AVFrame *f) { av_free(f->side.data); f->side.data = NULL; }
''' + helper + r'''
int main(void) {
    MediaCodecH264DecContext decoder = {.export_dovi = 1, .discard_before_us = -1};
    AVCodecContext codec = {&decoder, {1, 1000}, 0};
    uint8_t bytes[3] = {0, 0, 0};
    AVPacket packet = {.data = bytes, .size = 3};
    const int order[] = {2, 0, 1};
    for (int i = 0; i < 3; i++) {
        packet.pts = order[i]; bytes[2] = order[i] + 10;
        assert(mediacodec_dovi_packet(&codec, &packet) == 0);
    }
    AVFrame frame = {0};
    for (int i = 0; i < 3; i++) {
        output_pts = i;
        assert(mediacodec_dovi_receive(&codec, &frame, 0) == 0);
        assert(((AVDOVIMetadata *)frame.side.data)->marker == i + 10);
        assert(frame.color_range == AVCOL_RANGE_JPEG);
        av_frame_unref(&frame);
    }
    assert(alive == 0 && decoder.dovi_count == 0 && decoder.dovi_bytes == 0);
    output_pts = 42;
    assert(mediacodec_dovi_receive(&codec, &frame, 0) == AVERROR_INVALIDDATA);
    packet.pts = AV_NOPTS_VALUE;
    assert(mediacodec_dovi_packet(&codec, &packet) == AVERROR_INVALIDDATA);
    for (int i = 0; i < 128; i++) {
        packet.pts = i;
        assert(mediacodec_dovi_packet(&codec, &packet) == 0);
    }
    packet.pts = 128;
    assert(mediacodec_dovi_packet(&codec, &packet) == 0);
    assert(alive == 128 && decoder.dovi_count == 128);
    output_pts = 0; // Decoder later returning an evicted prefix must fail safely.
    assert(mediacodec_dovi_receive(&codec, &frame, 0) == AVERROR_INVALIDDATA);
    mediacodec_dovi_reset(&decoder); // A seek must release every old timeline RPU.
    assert(alive == 0 && decoder.dovi_count == 0 && decoder.dovi_bytes == 0);
    packet.pts = 4;
    assert(mediacodec_dovi_packet(&codec, &packet) == 0);
    output_pts = 4; output_format = 1; // Reject silent 8-bit output.
    assert(mediacodec_dovi_receive(&codec, &frame, 0) == AVERROR_INVALIDDATA);
    mediacodec_dovi_reset(&decoder);
    assert(alive == 0);
    decoder.discard_before_us = 5000; packet.pts = 4;
    assert(mediacodec_dovi_packet(&codec, &packet) == 0 && alive == 0);
    assert(decoder.dovi.marker == bytes[2]); // Parse RPU references without retaining preroll.
    packet.pts = 5;
    assert(mediacodec_dovi_packet(&codec, &packet) == 0 && alive == 1);
    mediacodec_dovi_reset(&decoder);
    assert(alive == 0);
    MediaCodecDecContext platform = {.discard_before_us = -1};
    decoder.ctx = &platform;
    decoder.discard_before_us = 20000;
    mediacodec_dovi_reset(&decoder);
    assert(platform.discard_before_us == 20000);
    decoder.discard_before_us = 5000; // Backward seek must retire the old cutoff.
    mediacodec_dovi_reset(&decoder);
    assert(platform.discard_before_us == 5000);
    decoder.export_dovi = 0;
    mediacodec_dovi_reset(&decoder);
    assert(platform.discard_before_us == -1);
    decoder.ctx = NULL; // Closing already freed the platform context.
    mediacodec_dovi_reset(&decoder);
    return 0;
}
''')


if __name__ == "__main__":
    unittest.main()
