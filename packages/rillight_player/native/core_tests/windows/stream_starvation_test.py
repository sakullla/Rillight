"""Check clock freeze and video recovery across a controlled HTTP starvation.

The sample must contain at least 25 seconds of seekable audio/video.
This checks native frames and control clocks, not displayed frames or sound.
"""

import argparse
import ctypes
import os
import time
import threading
import importlib.util
import re
import json
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

spec = importlib.util.spec_from_file_location(
    "probe", Path(__file__).with_name("loopback_http_seek_test.py")
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
Snapshot = m.Snapshot


class Frame(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("type", ctypes.c_int),
        ("session", ctypes.c_uint64),
        ("timeline", ctypes.c_uint64),
        ("pts", ctypes.c_int64),
        ("width", ctypes.c_int),
        ("height", ctypes.c_int),
        ("stride", ctypes.c_int),
        ("rate", ctypes.c_int),
        ("channels", ctypes.c_int),
        ("samples", ctypes.c_int),
        ("size", ctypes.c_int),
        ("data", ctypes.c_void_p),
    ]


def main():
    parser = argparse.ArgumentParser(
        description="Check video recovery and controls across an injected HTTP stall. Requires a seekable audio/video sample of at least 25 seconds."
    )
    parser.add_argument("--core", type=Path, required=True)
    parser.add_argument("--media", type=Path, required=True)
    args = parser.parse_args()
    media = args.media.resolve()
    size = media.stat().st_size
    gate = threading.Event()
    release = threading.Event()
    entered = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_GET(self):
            match = re.fullmatch("bytes=(\\d+)-(\\d*)", self.headers.get("Range", ""))
            start = int(match[1]) if match else 0
            end = min(int(match[2]), size - 1) if match and match[2] else size - 1
            self.send_response(206 if match else 200)
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Accept-Ranges", "bytes")
            if match:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            try:
                with media.open("rb") as stream:
                    stream.seek(start)
                    while start <= end:
                        if gate.is_set():
                            entered.set()
                            release.wait(15)
                        chunk = stream.read(min(65536, end - start + 1))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        self.wfile.flush()
                        start += len(chunk)
                        time.sleep(0.012)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    folder = args.core.resolve().parent
    results = {}
    with os.add_dll_directory(str(folder)):
        lib = ctypes.CDLL(str(args.core.resolve()))
        lib.rillight_core_create_loopback.restype = ctypes.c_void_p
        for name, arg_types in [
            ("destroy_loopback", [ctypes.c_void_p]),
            ("configure_hardware", [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]),
            ("set_video_output_size", [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]),
            ("open", [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint64]),
            ("snapshot", [ctypes.c_void_p, ctypes.POINTER(Snapshot)]),
            ("set_playing", [ctypes.c_void_p, ctypes.c_int, ctypes.c_uint64]),
            ("seek", [ctypes.c_void_p, ctypes.c_int64, ctypes.c_uint64]),
            ("set_speed", [ctypes.c_void_p, ctypes.c_double, ctypes.c_uint64]),
            ("take_frame", [ctypes.c_void_p, ctypes.c_int]),
            ("release_frame", [ctypes.c_void_p]),
            (
                "report_audio_unavailable",
                [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint64],
            ),
            (
                "report_audio_played",
                [
                    ctypes.c_void_p,
                    ctypes.c_uint64,
                    ctypes.c_uint64,
                    ctypes.c_int64,
                    ctypes.c_int64,
                ],
            ),
        ]:
            getattr(lib, "rillight_core_" + name).argtypes = arg_types
        lib.rillight_core_take_frame.restype = ctypes.c_void_p
        core = lib.rillight_core_create_loopback()
        assert lib.rillight_core_configure_hardware(core, 1, 0) == 0
        assert lib.rillight_core_set_video_output_size(core, 1280, 720) == 0
        assert (
            lib.rillight_core_open(
                core, f"http://127.0.0.1:{server.server_port}/sample.mkv".encode(), 1
            )
            == 0
        )
        operation = 1
        frames = 0
        pending = None
        submitted = -1
        quiet_at = None
        handed_off = False
        identity = None
        buffered_at = None
        freeze_position = None
        resumed_frames = None
        stage = "playing"
        step_at = 0
        start = time.monotonic()
        gate_at = 0
        try:
            while time.monotonic() - start < 35:
                now = time.monotonic()
                s = Snapshot()
                s.struct_size = ctypes.sizeof(s)
                lib.rillight_core_snapshot(core, ctypes.byref(s))
                assert s.state != 8, s.ffmpeg_error
                if (s.session_id, s.timeline_version) != identity:
                    if pending:
                        lib.rillight_core_release_frame(pending)
                    pending = None
                    submitted = -1
                    quiet_at = None
                    handed_off = False
                    identity = (s.session_id, s.timeline_version)
                if stage != "pause":
                    if not pending:
                        pending = lib.rillight_core_take_frame(core, 2)
                    if pending:
                        f = ctypes.cast(pending, ctypes.POINTER(Frame)).contents
                        if f.pts <= s.position_us + 180000:
                            handed_off = False
                            quiet_at = None
                            submitted = f.pts + round(
                                f.samples * 1000000 / 48000 * s.playback_speed
                            )
                            lib.rillight_core_release_frame(pending)
                            pending = None
                    if submitted >= 0 and (not handed_off):
                        lib.rillight_core_report_audio_played(
                            core,
                            s.session_id,
                            s.timeline_version,
                            submitted,
                            max(0, submitted - s.position_us),
                        )
                if (
                    not pending
                    and s.queued_audio_frames == 0
                    and (submitted >= 0)
                    and (s.position_us >= submitted)
                    and (s.queued_video_frames > 0)
                    and (s.state == 3)
                ):
                    if quiet_at is None:
                        quiet_at = now
                    if now - quiet_at > 0.15:
                        lib.rillight_core_report_audio_unavailable(
                            core, s.session_id, s.timeline_version
                        )
                        handed_off = True
                if frame := lib.rillight_core_take_frame(core, 1):
                    frames += 1
                    lib.rillight_core_release_frame(frame)
                if stage == "playing" and frames >= 60:
                    gate.set()
                    gate_at = now
                    stage = "stall"
                    print("Injected network stall", flush=True)
                if stage == "stall":
                    if s.state == 5:
                        if buffered_at is None:
                            buffered_at = now
                            freeze_position = s.position_us
                        if now - buffered_at > 0.4:
                            assert abs(s.position_us - freeze_position) < 10000, (
                                freeze_position,
                                s.position_us,
                            )
                            assert entered.is_set()
                            results["starvation_clock_frozen"] = True
                            release.set()
                            stage = "recover"
                            resumed_frames = frames
                            step_at = now
                    elif now - gate_at > 14:
                        raise RuntimeError("Buffering was not observed")
                if stage == "recover" and frames >= resumed_frames + 30:
                    results["frames_resume_after_stall"] = True
                    operation += 1
                    assert lib.rillight_core_set_playing(core, 0, operation) == 0
                    stage = "pause"
                    step_at = now
                    freeze_position = s.position_us
                if stage == "pause" and now - step_at > 0.4:
                    assert abs(s.position_us - freeze_position) < 10000
                    results["pause_clock_frozen"] = True
                    operation += 1
                    assert lib.rillight_core_set_playing(core, 1, operation) == 0
                    operation += 1
                    assert lib.rillight_core_set_speed(core, 2.0, operation) == 0
                    stage = "rate"
                    step_at = now
                    resumed_frames = frames
                if stage == "rate" and frames >= resumed_frames + 30:
                    assert s.playback_speed == 2.0
                    results["rate_2x_video_frames"] = True
                    operation += 1
                    assert lib.rillight_core_seek(core, 10000000, operation) == 0
                    stage = "seek"
                    step_at = now
                    resumed_frames = frames
                if stage == "seek" and frames >= resumed_frames + 30:
                    assert s.position_us >= 10000000
                    results["seek_video_frames"] = True
                    break
                time.sleep(0.001)
            assert all(
                (
                    results.get(key)
                    for key in [
                        "starvation_clock_frozen",
                        "frames_resume_after_stall",
                        "pause_clock_frozen",
                        "rate_2x_video_frames",
                        "seek_video_frames",
                    ]
                )
            ), results
            print(json.dumps(results), flush=True)
        finally:
            release.set()
            if pending:
                lib.rillight_core_release_frame(pending)
            lib.rillight_core_destroy_loopback(core)
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
