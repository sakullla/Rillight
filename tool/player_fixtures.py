"""Synthetic loopback Emby server and reproducible non-private media fixtures."""
import argparse
import json
import mimetypes
from pathlib import Path
import re
import subprocess
import struct
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


def av1_encoder(ffmpeg):
    encoders = subprocess.check_output(
        [ffmpeg, '-hide_banner', '-encoders'], text=True, stderr=subprocess.STDOUT)
    if 'libaom-av1' in encoders:
        return 'libaom-av1', ['-cpu-used', '8', '-row-mt', '1', '-threads', '4']
    if 'libsvtav1' in encoders:
        return 'libsvtav1', ['-preset', '12']
    raise RuntimeError('Need libaom-av1 or libsvtav1 to generate AV1 fixtures')


def generate(directory, ffmpeg):
    directory.mkdir(parents=True, exist_ok=True)
    if not (directory / 'sample.sup').exists():
        # Synthetic PGS display set: a visible white rectangle (no borrowed media).
        width, height = 320, 40
        rle = bytes([0, 0xC1, 0x40, 1, 0, 0]) * height
        def segment(kind, body, pts=0):
            return b'PG' + struct.pack('>IIBH', pts, 0, kind, len(body)) + body
        pcs = struct.pack('>HHBHBBBB', 1280, 720, 0x10, 0, 0x80, 0, 0, 1)
        pcs += struct.pack('>HBBHH', 0, 0, 0, 480, 600)
        wds = struct.pack('>BBHHHH', 1, 0, 480, 600, width, height)
        pds = bytes([0, 0, 0, 16, 128, 128, 0, 1, 235, 128, 128, 255])
        ods = bytes([0, 0, 0, 0xC0]) + (len(rle) + 4).to_bytes(3, 'big') + struct.pack('>HH', width, height) + rle
        clear = struct.pack('>HHBHBBBB', 1280, 720, 0x10, 1, 0, 0, 0, 0)
        (directory / 'sample.sup').write_bytes(segment(0x16, pcs) + segment(0x17, wds)
            + segment(0x14, pds) + segment(0x15, ods) + segment(0x80, b'')
            + segment(0x16, clear, 900000) + segment(0x80, b'', 900000))
    for name, size, fps, codec in [('baseline.mp4', '1280x720', 30, 'libx264'),
                                  ('timeout.mp4', '640x360', 30, 'libx264'),
                                  ('1080p60.mp4', '1920x1080', 60, 'libx264'),
                                  ('4k-hevc.mkv', '3840x2160', 30, 'libx265')]:
        if (directory / name).exists():
            continue
        subprocess.run([ffmpeg, '-y', '-f', 'lavfi', '-i', f'testsrc2=size={size}:rate={fps}',
                        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
                        '-t', '30' if name == 'timeout.mp4' else '12', '-c:v', codec, '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
                        '-c:a', 'aac', str(directory / name)], check=True)
    (directory / 'sample.ass').write_text('''[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,30,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:12.00,Default,,0,0,0,,Rillight ASS validation
''', encoding='utf-8')
    if not (directory / 'stream.m3u8').exists():
        subprocess.run([ffmpeg, '-y', '-i', str(directory / 'baseline.mp4'), '-c', 'copy',
                        '-hls_time', '2', '-hls_list_size', '0', str(directory / 'stream.m3u8')], check=True)
    av1_codec, av1_extra = av1_encoder(ffmpeg)
    for name, codec, extra in [('av1.mkv', av1_codec, av1_extra),
                               ('vp9.webm', 'libvpx-vp9', ['-deadline', 'realtime', '-cpu-used', '8'])]:
        if not (directory / name).exists():
            subprocess.run([ffmpeg, '-y', '-i', str(directory / 'baseline.mp4'), '-t', '4',
                            '-vf', 'scale=320:180', '-c:v', codec, *extra, '-c:a', 'libopus',
                            str(directory / name)], check=True)
    for extension in ['srt', 'vtt', 'ssa']:
        subprocess.run([ffmpeg, '-y', '-i', str(directory / 'sample.ass'),
                        str(directory / ('sample.' + extension))], check=True, capture_output=True)
    # Existing synthetic PGS fixture is needed because FFmpeg has no PGS encoder.
    # Never substitute an ASS track and label it PGS.
    if not (directory / 'tracks-long.mkv').exists():
        if not (directory / 'sample.sup').exists():
            raise RuntimeError('PGS validation requires a synthetic sample.sup fixture')
        subprocess.run([ffmpeg, '-y', '-stream_loop', '2', '-i', str(directory / 'baseline.mp4'), '-f', 'lavfi', '-i',
                        'sine=frequency=880:sample_rate=48000', '-i', str(directory / 'sample.sup'),
                        '-i', str(directory / 'sample.ass'), '-map', '0:v', '-map', '0:a', '-map', '1:a',
                        '-map', '2:s', '-map', '3:s', '-t', '30', '-c:v', 'copy', '-c:a', 'aac', '-c:s', 'copy',
                        str(directory / 'tracks-long.mkv')], check=True)


def serve(media, output):
    conditions = {'offline': False}
    paths = {'baseline': 'baseline.mp4', 'delayed-report': 'timeout.mp4', 'delayed-subtitle': 'timeout.mp4', 'tracks': 'tracks-long.mkv', 'hls': 'stream.m3u8',
             '1080p60': '1080p60.mp4', '4k-hevc': '4k-hevc.mkv', 'av1': 'av1.mkv',
             'vp9': 'vp9.webm', 'broken': 'missing.mkv'}
    user = {'Id': 'validation-user', 'Name': 'validation', 'Configuration': {'EnableNextEpisodeAutoPlay': False}}
    def item(identifier):
        return {'Id': identifier, 'Name': identifier, 'Type': 'Movie', 'RunTimeTicks': 300000000 if identifier.startswith('delayed-') or identifier == 'tracks' else 120000000,
                'UserData': {'PlaybackPositionTicks': 20000000 if identifier == 'baseline' else 0}, 'MediaType': 'Video'}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *_):
            pass
        def send_json(self, value, status=200):
            body = json.dumps(value).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def do_POST(self):
            length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(length) or b'{}')
            path = urlsplit(self.path).path
            if path == '/validation/network':
                conditions['offline'] = body.get('offline') is True
                self.send_json(conditions)
            elif path.endswith('/AuthenticateByName'):
                self.send_json({'AccessToken': 'synthetic-validation-token', 'User': user, 'ServerId': 'validation-server'})
            elif path.endswith('/PlaybackInfo'):
                identifier = path.split('/')[-2]
                streams = [{'Index': 0, 'Type': 'Video', 'Codec': 'hevc' if identifier == '4k-hevc' else 'h264'},
                           {'Index': 1, 'Type': 'Audio', 'Codec': 'aac', 'IsDefault': True}]
                if identifier == 'tracks':
                    streams += [{'Index': 2, 'Type': 'Audio', 'Codec': 'aac'},
                                {'Index': 3, 'Type': 'Subtitle', 'Codec': 'pgssub', 'IsTextSubtitleStream': False},
                                {'Index': 4, 'Type': 'Subtitle', 'Codec': 'ass', 'IsTextSubtitleStream': True},
                                *[{'Index': i, 'Type': 'Subtitle', 'Codec': codec,
                                   'IsTextSubtitleStream': True, 'IsExternal': True}
                                  for i, codec in [(5, 'srt'), (6, 'vtt'), (7, 'ssa')]]]
                source = {'Id': identifier, 'Container': 'mkv' if identifier == 'tracks' else 'mp4',
                          'Name': identifier, 'RunTimeTicks': item(identifier)['RunTimeTicks'],
                          'SupportsDirectPlay': identifier != 'hls', 'SupportsDirectStream': identifier != 'hls',
                          'DefaultAudioStreamIndex': 1, 'MediaStreams': streams,
                          'TranscodingUrl' if identifier == 'hls' else 'DirectStreamUrl': '/media/' + paths[identifier]}
                if identifier == 'delayed-subtitle':
                    streams.append({'Index': 8, 'Type': 'Subtitle', 'Codec': 'srt',
                                    'IsTextSubtitleStream': True, 'IsExternal': True})
                    source['DefaultSubtitleStreamIndex'] = 8
                self.send_json({'PlaySessionId': identifier + '-session', 'MediaSources': [source]})
            elif path.startswith('/Sessions/'):
                with (output / 'reports.jsonl').open('a', encoding='utf-8') as log:
                    log.write(json.dumps({'path': path, 'body': body}) + '\n')
                if path == '/Sessions/Playing' and body.get('ItemId') == 'delayed-report':
                    # Exercise the client's real 15-second receive deadline.
                    time.sleep(18)
                try:
                    self.send_json({})
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    pass
            else:
                self.send_json({})
        def do_GET(self):
            path = urlsplit(self.path).path
            if path == '/System/Info/Public':
                self.send_json({'Id': 'validation-server', 'ServerName': 'Rillight validation', 'Version': '4.9.0'})
            elif path == '/Users/validation-user':
                self.send_json(user)
            elif re.fullmatch(r'/Users/validation-user/Items/[^/]+', path) and path.split('/')[-1] in paths:
                self.send_json(item(path.split('/')[-1]))
            elif path.startswith('/media/') or '/Subtitles/' in path:
                if '/delayed-subtitle/' in path and '/Subtitles/' in path:
                    with (output / 'subtitle-requests.jsonl').open('a', encoding='utf-8') as log:
                        log.write(json.dumps({'path': path, 'started': time.time()}) + '\n')
                    time.sleep(18)
                    # The controller downloads before native sub-add and uses
                    # a 60 s HTTP deadline. Deliver an invalid subtitle to test
                    # a bounded optional-track failure without changing that
                    # production policy or waiting through three HTTP retries.
                    self.send_json({'error': 'synthetic invalid subtitle'})
                    return
                if conditions['offline']:
                    self.send_json({'error': 'synthetic outage'}, 503)
                    return
                filename = ('sample.' + path.split('.')[-1]) if '/Subtitles/' in path else path.removeprefix('/media/')
                target = (media / filename).resolve()
                if not target.is_relative_to(media) or not target.is_file():
                    self.send_json({'error': 'missing fixture'}, 404)
                    return
                size = target.stat().st_size
                start, end = 0, size - 1
                match = re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers.get('Range', ''))
                if match:
                    start = int(match[1]); end = min(end, int(match[2])) if match[2] else end
                self.send_response(206 if match else 200)
                self.send_header('Content-Type', 'application/vnd.apple.mpegurl' if target.suffix == '.m3u8' else mimetypes.guess_type(target)[0] or 'application/octet-stream')
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('ETag', f'"fixture-{size}-{target.stat().st_mtime_ns}"')
                self.send_header('Cache-Control', 'max-age=600')
                self.send_header('Content-Length', str(end - start + 1))
                if match: self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
                self.end_headers()
                try:
                    with target.open('rb') as stream:
                        stream.seek(start)
                        left = end - start + 1
                        while left > 0:
                            chunk = stream.read(min(left, 65536)); self.wfile.write(chunk); left -= len(chunk)
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    pass
            else:
                self.send_json({'Items': [item('baseline')], 'TotalRecordCount': 1})

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    output.mkdir(parents=True, exist_ok=True)
    (output / 'server.json').write_text(json.dumps({'url': f'http://127.0.0.1:{server.server_port}'}), encoding='utf-8')
    server.serve_forever()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--media', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--ffmpeg')
    args = parser.parse_args()
    if args.ffmpeg: generate(args.media.resolve(), args.ffmpeg)
    if args.output: serve(args.media.resolve(), args.output.resolve())
