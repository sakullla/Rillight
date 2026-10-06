"""Measure core first decoded frame through a synthetic, sealed loopback route.

This does not establish displayed Flutter pixels or physical audio output.
The companion Dart harness owns the proxy, cache, and delayed media origin.
"""
import argparse
import ctypes as c
import importlib.util
import json
import os
from pathlib import Path
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core-directory', type=Path, required=True)
    parser.add_argument('--url', required=True)
    parser.add_argument('--resume-ms', type=int, default=0)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location(
        'probe', Path(__file__).resolve().parents[1] /
        'packages/rillight_player/native/core_tests/windows/loopback_http_seek_test.py')
    probe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(probe)
    folder = args.core_directory.resolve()
    with os.add_dll_directory(str(folder)):
        lib = c.CDLL(str(folder / 'librillight_core.dll'))
        lib.rillight_core_create_loopback.restype = c.c_void_p
        lib.rillight_core_open_at.argtypes = [c.c_void_p, c.c_char_p, c.c_int64, c.c_uint64]
        lib.rillight_core_snapshot.argtypes = [c.c_void_p, c.POINTER(probe.Snapshot)]
        lib.rillight_core_destroy_loopback.argtypes = [c.c_void_p]
        lib.rillight_core_take_frame.argtypes = [c.c_void_p, c.c_int]
        lib.rillight_core_take_frame.restype = c.c_void_p
        lib.rillight_core_release_frame.argtypes = [c.c_void_p]
        core = lib.rillight_core_create_loopback()
        start = time.monotonic()
        try:
            lib.rillight_core_open_at(core, args.url.encode(), args.resume_ms * 1000, 1)
            while time.monotonic() - start < 30:
                value = probe.Snapshot()
                value.struct_size = c.sizeof(value)
                lib.rillight_core_snapshot(core, c.byref(value))
                if value.state == 8:
                    raise RuntimeError(f'Core failure: {value.ffmpeg_error}')
                if value.first_video_frame_ready:
                    print(json.dumps({
                        'firstDecodedFrameMs': round((time.monotonic() - start) * 1000),
                        'positionMs': value.position_us // 1000,
                        'audio': value.audio_stream_index, 'video': value.video_stream_index,
                    }), flush=True)
                    break
                for kind in [1, 2]:
                    while frame := lib.rillight_core_take_frame(core, kind):
                        lib.rillight_core_release_frame(frame)
                time.sleep(.005)
            else:
                raise TimeoutError('Native open timeout')
        finally:
            lib.rillight_core_destroy_loopback(core)


if __name__ == '__main__':
    main()
