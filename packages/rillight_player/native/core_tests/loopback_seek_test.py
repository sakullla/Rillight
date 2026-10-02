"""Verify absolute PCM bytes after cancelling and reopening an HTTP seek."""
import ctypes
import http.server
import re
import struct
import sys
import threading
import time


class Frame(ctypes.Structure):
    _fields_ = [
        ('struct_size', ctypes.c_uint32), ('type', ctypes.c_int),
        ('session', ctypes.c_uint64), ('timeline', ctypes.c_uint64),
        ('pts_us', ctypes.c_int64),
        *[(name, ctypes.c_int) for name in
          ('width', 'height', 'stride', 'sample_rate', 'channels',
           'sample_count', 'data_size')],
        ('data', ctypes.POINTER(ctypes.c_uint8)),
    ]


def main():
    pcm = b''.join(struct.pack('<hh', i % 1000, i % 1000)
                   for i in range(48000 * 8))
    media = (b'RIFF' + struct.pack('<I', len(pcm) + 36) + b'WAVEfmt ' +
             struct.pack('<IHHIIHH', 16, 1, 2, 48000, 192000, 4, 16) +
             b'data' + struct.pack('<I', len(pcm)) + pcm)
    ranges = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            match = re.fullmatch(r'bytes=(\d+)-(\d*)',
                                 self.headers.get('Range', 'bytes=0-'))
            start = int(match[1])
            end = min(int(match[2]) if match[2] else len(media) - 1,
                      len(media) - 1)
            ranges.append(start)
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(media)}')
            self.send_header('Content-Length', str(end - start + 1))
            self.end_headers()
            try:
                self.wfile.write(media[start:end + 1])
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    core = ctypes.CDLL(sys.argv[1])
    core.rillight_core_create_loopback.restype = ctypes.c_void_p
    core.rillight_core_open.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint64]
    core.rillight_core_set_playing.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_uint64]
    core.rillight_core_seek.argtypes = [ctypes.c_void_p, ctypes.c_int64, ctypes.c_uint64]
    core.rillight_core_take_frame.argtypes = [ctypes.c_void_p, ctypes.c_int]
    core.rillight_core_take_frame.restype = ctypes.POINTER(Frame)
    core.rillight_core_release_frame.argtypes = [ctypes.POINTER(Frame)]
    core.rillight_core_destroy_loopback.argtypes = [ctypes.c_void_p]
    handle = core.rillight_core_create_loopback()

    def take():
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            frame = core.rillight_core_take_frame(handle, 2)
            if frame:
                return frame
            time.sleep(.001)
        raise AssertionError('No audio frame after the HTTP operation')

    try:
        url = f'http://127.0.0.1:{server.server_port}/seek.wav'.encode()
        assert core.rillight_core_open(handle, url, 1) == 0
        while True:
            frame = take()
            pts = frame.contents.pts_us
            core.rillight_core_release_frame(frame)
            if pts >= 500000:
                break
        assert core.rillight_core_set_playing(handle, 0, 2) == 0
        assert core.rillight_core_seek(handle, 0, 3) == 0
        frame = take()
        try:
            sample = ctypes.cast(frame.contents.data, ctypes.POINTER(ctypes.c_int16))[0]
            assert frame.contents.timeline >= 2
            assert frame.contents.pts_us == 0
            assert sample == 0, f'Reopened PCM cursor shifted: expected 0, got {sample}'
            assert 44 in ranges, f'Test did not exercise the small-offset reopen: {ranges}'
        finally:
            core.rillight_core_release_frame(frame)
    finally:
        core.rillight_core_destroy_loopback(handle)
        server.shutdown()
        server.server_close()
    print('Small-offset loopback reopen preserves absolute PCM position')


if __name__ == '__main__':
    main()
