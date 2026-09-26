"""Exercise the published native loopback core across an interrupted HTTP read.

Run with --core and --media from a verified Windows SDK and generated MP4.
"""

import argparse
import ctypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import re
import socket
import sys
import threading
import time


class Snapshot(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32), ("abi_version", ctypes.c_uint32),
        ("session_id", ctypes.c_uint64), ("operation_id", ctypes.c_uint64),
        ("timeline_version", ctypes.c_uint64), ("state", ctypes.c_int),
        ("ffmpeg_error", ctypes.c_int), ("video_stream_index", ctypes.c_int),
        ("audio_stream_index", ctypes.c_int), ("subtitle_stream_index", ctypes.c_int),
        ("duration_us", ctypes.c_int64), ("position_us", ctypes.c_int64),
        ("first_video_frame_ready", ctypes.c_int),
        ("first_audio_frame_ready", ctypes.c_int), ("source_eof", ctypes.c_int),
        ("queued_video_frames", ctypes.c_int), ("queued_audio_frames", ctypes.c_int),
        ("playback_speed", ctypes.c_double), ("preferred_hardware", ctypes.c_uint32),
        ("allow_software_fallback", ctypes.c_int),
        ("external_subtitle_pending", ctypes.c_int),
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", type=Path, required=True)
    parser.add_argument("--media", type=Path, required=True)
    parser.add_argument("--drop-once", action="store_true")
    parser.add_argument("--subtitle", action="store_true")
    parser.add_argument("--switch-subtitles", action="store_true")
    args = parser.parse_args()
    core_path, media_path = args.core.resolve(), args.media.resolve()
    if not core_path.is_file() or not media_path.is_file():
        parser.error("core DLL and media must exist")
    gate_armed = threading.Event()
    gate_entered = threading.Event()
    gate_release = threading.Event()
    drop_armed = threading.Event()
    dropped = threading.Event()
    requests = []
    size = media_path.stat().st_size

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path == "/sample.srt":
                subtitle = b"1\n00:00:01,000 --> 00:00:02,000\nLOOPBACK SRT\n\n"
                self.send_response(200)
                self.send_header("Content-Type", "application/x-subrip")
                self.send_header("Content-Length", str(len(subtitle)))
                self.end_headers()
                self.wfile.write(subtitle)
                return
            if self.path != "/fixture.mp4":
                self.send_error(404)
                return
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
            start = int(match[1]) if match else 0
            end = min(int(match[2]), size - 1) if match and match[2] else size - 1
            requests.append((start, end))
            self.send_response(206 if match else 200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            if match:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            try:
                with media_path.open("rb") as stream:
                    stream.seek(start)
                    while start <= end:
                        if drop_armed.is_set():
                            drop_armed.clear()
                            dropped.set()
                            self.connection.shutdown(socket.SHUT_RDWR)
                            return
                        if gate_armed.is_set():
                            gate_armed.clear()
                            gate_entered.set()
                            gate_release.wait(8)
                        chunk = stream.read(min(16384, end - start + 1))
                        self.wfile.write(chunk)
                        self.wfile.flush()
                        start += len(chunk)
                        time.sleep(0.01)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    try:
        with os.add_dll_directory(str(core_path.parent)):
            library = ctypes.CDLL(str(core_path))
            library.rillight_core_create_loopback.restype = ctypes.c_void_p
            library.rillight_core_destroy_loopback.argtypes = [ctypes.c_void_p]
            library.rillight_core_open.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                                   ctypes.c_uint64]
            library.rillight_core_seek.argtypes = [ctypes.c_void_p, ctypes.c_int64,
                                                   ctypes.c_uint64]
            library.rillight_core_set_playing.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                                          ctypes.c_uint64]
            library.rillight_core_add_external_subtitle.argtypes = [
                ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint64]
            library.rillight_core_select_subtitle.argtypes = [
                ctypes.c_void_p, ctypes.c_int, ctypes.c_uint64]
            library.rillight_core_track_count.argtypes = [ctypes.c_void_p]
            library.rillight_core_snapshot.argtypes = [ctypes.c_void_p,
                                                       ctypes.POINTER(Snapshot)]
            library.rillight_core_take_frame.argtypes = [ctypes.c_void_p, ctypes.c_int]
            library.rillight_core_take_frame.restype = ctypes.c_void_p
            library.rillight_core_release_frame.argtypes = [ctypes.c_void_p]
            core = library.rillight_core_create_loopback()
            if not core:
                raise AssertionError("Could not create loopback core")
            try:
                url = f"http://127.0.0.1:{server.server_port}/fixture.mp4".encode()
                if library.rillight_core_open(core, url, 1) != 0:
                    raise AssertionError("Core open rejected")
                if library.rillight_core_set_playing(core, 1, 2) != 0:
                    raise AssertionError("Core play rejected")

                def snapshot():
                    value = Snapshot()
                    value.struct_size = ctypes.sizeof(Snapshot)
                    if library.rillight_core_snapshot(core, ctypes.byref(value)) != 0:
                        raise AssertionError("Core snapshot failed")
                    return value

                def drain():
                    for frame_type in (1, 2):
                        while frame := library.rillight_core_take_frame(core, frame_type):
                            library.rillight_core_release_frame(frame)

                def wait_for(predicate, label, timeout=15):
                    deadline = time.monotonic() + timeout
                    last = None
                    while time.monotonic() < deadline:
                        last = snapshot()
                        if last.state == 8:
                            raise AssertionError(
                                f"{label}: core failed {last.ffmpeg_error} "
                                f"timeline={last.timeline_version} requests={requests[-6:]}")
                        if predicate(last):
                            return last
                        drain()
                        time.sleep(0.01)
                    raise AssertionError(
                        f"{label}: timed out state={last.state if last else None} "
                        f"timeline={last.timeline_version if last else None} "
                        f"requests={requests[-6:]}")

                current = wait_for(lambda value: value.first_video_frame_ready,
                                   "initial video")
                if args.switch_subtitles:
                    for index, operation in ((3, 3), (4, 4)):
                        completed = threading.Event()
                        outcome = []

                        def select():
                            outcome.append(library.rillight_core_select_subtitle(
                                core, index, operation))
                            completed.set()

                        threading.Thread(target=select, daemon=True).start()
                        if not completed.wait(10):
                            print(f"Native subtitle selection {index} blocked",
                                  file=sys.stderr, flush=True)
                            os._exit(1)
                        if outcome != [0]:
                            raise AssertionError(
                                f"Native subtitle selection {index} rejected: "
                                f"state={snapshot().state}")
                        current = wait_for(
                            lambda value: value.subtitle_stream_index == index,
                            f"subtitle {index}")
                        if index == 3:
                            deadline = time.monotonic() + 2
                            while time.monotonic() < deadline:
                                drain()
                                time.sleep(0.01)
                    print("PGS to ASS switch confirmed on loopback core")
                    return
                if args.subtitle:
                    before_tracks = library.rillight_core_track_count(core)
                    subtitle_url = (f"http://127.0.0.1:{server.server_port}/sample.srt"
                                    .encode())
                    if library.rillight_core_add_external_subtitle(
                            core, subtitle_url, 3) != 0:
                        raise AssertionError("External subtitle command rejected")
                    deadline = time.monotonic() + 8
                    while time.monotonic() < deadline:
                        state = snapshot()
                        if not state.external_subtitle_pending:
                            break
                        drain()
                        time.sleep(0.01)
                    after_tracks = library.rillight_core_track_count(core)
                    if state.external_subtitle_pending or after_tracks != before_tracks + 1:
                        raise AssertionError(
                            f"HTTP subtitle did not load: error={state.ffmpeg_error} "
                            f"tracks={before_tracks}->{after_tracks}")
                if args.drop_once:
                    drop_armed.set()
                    deadline = time.monotonic() + 8
                    while not dropped.is_set() and time.monotonic() < deadline:
                        drain()
                        time.sleep(0.01)
                    if not dropped.is_set():
                        raise AssertionError("HTTP close was not injected")
                    deadline = time.monotonic() + 2
                    while time.monotonic() < deadline:
                        current = snapshot()
                        if current.state in (7, 8):
                            raise AssertionError(
                                f"Premature HTTP close ended playback: "
                                f"state={current.state} error={current.ffmpeg_error}")
                        drain()
                        time.sleep(0.01)
                for operation in range(4 if args.subtitle else 3, 23):
                    target = (2_000_000, 8_000_000, 14_000_000)[operation % 3]
                    gate_release.clear()
                    gate_entered.clear()
                    gate_armed.set()
                    gate_deadline = time.monotonic() + 5
                    while not gate_entered.is_set() and time.monotonic() < gate_deadline:
                        value = snapshot()
                        if value.state == 8:
                            raise AssertionError(
                                f"HTTP read failed before gate: {value.ffmpeg_error}")
                        drain()
                        time.sleep(0.01)
                    if not gate_entered.is_set():
                        value = snapshot()
                        raise AssertionError(
                            f"HTTP read gate did not enter; test inconclusive "
                            f"state={value.state} error={value.ffmpeg_error} "
                            f"queued={value.queued_video_frames}/"
                            f"{value.queued_audio_frames} requests={requests[-6:]}")
                    old_timeline = current.timeline_version
                    if library.rillight_core_seek(core, target, operation) != 0:
                        raise AssertionError(f"Seek {operation} rejected")
                    gate_release.set()
                    current = wait_for(
                        lambda value: value.timeline_version > old_timeline
                        and value.first_video_frame_ready,
                        f"video after interrupted seek {operation}")
                print(f"loopback HTTP seeks survived: requests={len(requests)}, "
                      f"timeline={current.timeline_version}")
            finally:
                gate_release.set()
                library.rillight_core_destroy_loopback(core)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
