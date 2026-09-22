"""Synthetic native-player HTTP fixture. No real credentials or Emby server.

Serve an existing media directory on 8765/8766. adb reverse both ports.
The second origin rejects any leaked synthetic token. /__checks exposes counts
without credential material. Supports both Range and intentionally ignored Range.
"""
import argparse
import functools
import http.server
import json
import pathlib
import re
import threading
import urllib.parse

TOKEN = "synthetic-android-smoke"
counts = {"authorized": 0, "cross_origin": 0, "leaks": 0, "ranges": 0}
lock = threading.Lock()


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass  # URLs can intentionally contain synthetic tokens; never log them.

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        remote = self.server.server_port == 8766
        if parsed.path == "/__checks":
            self.reply(200, json.dumps(counts).encode(), "application/json")
            return
        leaked = TOKEN in urllib.parse.unquote(self.path) or any(
            TOKEN in value for value in self.headers.values()
        )
        with lock:
            if remote:
                counts["cross_origin"] += 1
                counts["leaks"] += int(leaked)
            else:
                counts["authorized"] += int(self.headers.get("X-Emby-Token") == TOKEN)
        if remote and leaked:
            self.reply(403, b"credential leak")
            return
        if not remote and parsed.path not in ("/unauthorized.mp4",) and self.headers.get("X-Emby-Token") != TOKEN:
            self.reply(401, b"synthetic authentication required")
            return
        if parsed.path == "/unauthorized.mp4":
            self.reply(401, b"synthetic expired identity")
            return
        if parsed.path == "/redirect.mkv":
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:8766/android-tracks.mkv?api_key={TOKEN}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if parsed.path == "/cross-origin.m3u8":
            content = (pathlib.Path(self.directory) / "stream.m3u8").read_text()
            content = "\n".join(
                f"http://127.0.0.1:8766/{line}?api_key={TOKEN}" if line and not line.startswith("#") else line
                for line in content.splitlines()
            )
            self.reply(200, content.encode(), "application/vnd.apple.mpegurl")
            return
        path = pathlib.Path(self.translate_path(parsed.path))
        if not path.is_file():
            self.reply(404, b"synthetic missing media")
            return
        size = path.stat().st_size
        start, end = 0, size - 1
        requested = self.headers.get("Range")
        match = re.fullmatch(r"bytes=(\d+)-(\d*)", requested or "")
        if match:
            start = int(match[1])
            end = min(int(match[2]) if match[2] else end, end)
            if start > end:
                self.reply(416, b"range unavailable")
                return
            with lock:
                counts["ranges"] += 1
        self.send_response(206 if match else 200)
        self.send_header("Content-Type", self.guess_type(str(path)))
        self.send_header("Content-Length", str(end - start + 1))
        if match:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        try:
            with path.open("rb") as media:
                media.seek(start)
                remaining = end - start + 1
                while remaining:
                    data = media.read(min(65536, remaining))
                    if not data:
                        break
                    self.wfile.write(data)
                    remaining -= len(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def reply(self, status, body, content_type="text/plain"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("media_dir", type=pathlib.Path)
    args = parser.parse_args()
    handler = functools.partial(Handler, directory=str(args.media_dir.resolve()))
    remote = http.server.ThreadingHTTPServer(("127.0.0.1", 8766), handler)
    threading.Thread(target=remote.serve_forever, daemon=True).start()
    origin = http.server.ThreadingHTTPServer(("127.0.0.1", 8765), handler)
    print("Synthetic media origins ready on 8765/8766", flush=True)
    try:
        origin.serve_forever()
    finally:
        origin.server_close()
        remote.shutdown()
        remote.server_close()


if __name__ == "__main__":
    main()
