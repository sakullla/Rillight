"""Loopback-only synthetic Emby and deterministic Android media; no private data."""
import argparse
import hashlib
import json
import mimetypes
from pathlib import Path
import re
import struct
import subprocess
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=8784)
parser.add_argument('--generate', action='store_true')
parser.add_argument('--ffmpeg', default='ffmpeg')
parser.add_argument('--media', type=Path, required=True)
parser.add_argument('--output', type=Path, default=Path('build/android-validation/fixture'))
args = parser.parse_args()
media = args.media.resolve()
if args.generate:
    media.mkdir(parents=True, exist_ok=True)
    (media / 'sample.srt').write_text('1\n00:00:00,000 --> 00:01:00,000\nANDROID EMBEDDED SRT\n', encoding='utf-8')
    (media / 'sample.vtt').write_text('WEBVTT\n\n00:00.000 --> 01:00.000\nANDROID EXTERNAL WEBVTT\n', encoding='utf-8')
    subprocess.run([args.ffmpeg, '-y', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30',
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
        '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=48000', '-i', str(media / 'sample.srt'),
        '-map', '0:v', '-map', '1:a', '-map', '2:a', '-map', '3:s', '-t', '60',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-ac', '2', '-c:s', 'srt',
        '-metadata:s:a:0', 'language=eng', '-metadata:s:a:1', 'language=zho',
        '-metadata:s:s:0', 'language=eng', str(media / 'android-tracks.mkv')], check=True, timeout=180)
    subprocess.run([args.ffmpeg, '-y', '-i', str(media / 'android-tracks.mkv'), '-map', '0:v', '-map', '0:a:0',
        '-t', '12', '-c', 'copy', '-hls_time', '2', '-hls_list_size', '0', str(media / 'stream.m3u8')], check=True, timeout=60)
    raise SystemExit(0)
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
lock = threading.RLock()
conditions = dict(offline=False, expired=False, auth_fail=False, empty=False, report_fail=False,
                  media_fail=False, subtitle_delay_ms=0, catalog_delay_ms=0)
positions = {'movie-01': 20000000}
played = set()
reports = []
requests = []
token = 'synthetic-mobile-token'
user = {'Id': 'mobile-user', 'Name': 'mobile',
        'Configuration': {'EnableNextEpisodeAutoPlay': False},
        'Policy': {'EnableMediaPlayback': True}}
views = [{'Id': 'movies', 'Name': '电影', 'Type': 'CollectionFolder', 'CollectionType': 'movies',
          'ImageTags': {'Primary': 'fixture'}},
         {'Id': 'shows', 'Name': '剧集', 'Type': 'CollectionFolder', 'CollectionType': 'tvshows',
          'ImageTags': {'Primary': 'fixture'}}]
items = {}


def add(identifier, name, kind, **extra):
    items[identifier] = dict(Id=identifier, Name=name, Type=kind,
        Overview='用于验证手机与电视浏览、详情、播放和失败恢复的合成内容。所有画面和音频均为测试信号。',
        ProductionYear=2026, PremiereDate='2026-01-01T00:00:00Z',
        DateCreated='2026-09-22T00:00:00Z', CommunityRating=8.2,
        RunTimeTicks=600210000, ImageTags={'Primary': 'fixture', 'Thumb': 'fixture'},
        BackdropImageTags=['fixture'], Genres=['测试', '演示'], **extra)


for i in range(1, 49):
    add(f'movie-{i:02}', f'Rillight 流光验证 {i:02}', 'Movie', ParentId='movies')
add('hls', 'Rillight HLS 字幕回退', 'Movie', ParentId='movies')
add('broken', 'Rillight 播放失败', 'Movie', ParentId='movies')
add('no-media', 'Rillight 无可播放媒体', 'Movie', ParentId='movies')
for series in range(1, 5):
    sid = f'series-{series}'
    add(sid, f'Rillight 合成剧集 {series}', 'Series', ParentId='shows', ChildCount=2)
    for season in range(1, 3):
        season_id = f'{sid}-season-{season}'
        add(season_id, f'第 {season} 季', 'Season', ParentId=sid, SeriesId=sid,
            SeriesName=items[sid]['Name'], IndexNumber=season, ChildCount=6)
        for episode in range(1, 7):
            add(f'{season_id}-episode-{episode}', f'测试第 {episode} 集', 'Episode',
                ParentId=season_id, SeriesId=sid, SeasonId=season_id,
                SeriesName=items[sid]['Name'], IndexNumber=episode, ParentIndexNumber=season)


def source(identifier, force=False):
    hls = identifier == 'hls' or force
    streams = [{'Index': 0, 'Type': 'Video', 'Codec': 'h264', 'Width': 1280, 'Height': 720},
               {'Index': 1, 'Type': 'Audio', 'Codec': 'aac', 'Language': 'eng', 'IsDefault': True}]
    if not hls:
        streams += [{'Index': 2, 'Type': 'Audio', 'Codec': 'aac', 'Language': 'zho'},
                    {'Index': 3, 'Type': 'Subtitle', 'Codec': 'srt', 'Language': 'eng',
                     'IsTextSubtitleStream': True, 'IsExternal': False}]
    streams += [{'Index': 4, 'Type': 'Subtitle', 'Codec': 'vtt', 'Language': 'zho',
                 'DisplayTitle': '外挂测试字幕', 'IsTextSubtitleStream': True,
                 'IsExternal': True, 'DeliveryMethod': 'External',
                 'DeliveryUrl': '/media/sample.vtt'}]
    result = {'Id': identifier + '-source', 'Name': '合成测试源',
              'Container': 'ts' if hls else 'mkv', 'RunTimeTicks': 120000000 if hls else 600210000,
              'SupportsDirectPlay': not hls, 'SupportsDirectStream': not hls,
              'SupportsTranscoding': True, 'DefaultAudioStreamIndex': 1,
              'DefaultSubtitleStreamIndex': 4 if hls else 3, 'MediaStreams': streams}
    if hls:
        result['TranscodingUrl'] = '/media/stream.m3u8'
    else:
        result['DirectStreamUrl'] = '/media/missing.mkv' if identifier == 'broken' else '/media/android-tracks.mkv'
    return result


def item(identifier):
    result = dict(items[identifier])
    result['UserData'] = {'PlaybackPositionTicks': positions.get(identifier, 0),
                          'Played': identifier in played, 'IsFavorite': False}
    if result['Type'] in ('Movie', 'Episode'):
        result['MediaType'] = 'Video'
        result['MediaSources'] = [] if identifier == 'no-media' else [source(identifier)]
    return result


def poster(identifier, landscape=False):
    width, height = (320, 180) if landscape else (180, 270)
    color = hashlib.sha256(identifier.encode()).digest()
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            band = 45 if (x + y // 2) % 85 < 22 else 0
            rows.extend(min(255, 20 + color[c] // 2 + y * 50 // height + band) for c in range(3))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_):
        pass

    def reply(self, value, status=200, mime='application/json'):
        body = value if isinstance(value, bytes) else json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def body(self):
        return json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')

    def parsed(self):
        parsed = urlsplit(self.path)
        path = unquote(parsed.path)
        if path.startswith('/emby/'):
            path = path[5:]
        query = {key.lower(): values[0] for key, values in parse_qs(parsed.query).items()}
        if not path.startswith('/__'):
            with lock:
                requests.append({'method': self.command, 'path': path, 'time': time.time()})
        return path, query

    def authorized(self, query):
        if conditions['offline']:
            self.reply({'Error': 'synthetic network outage'}, 503)
            return False
        supplied = self.headers.get('X-Emby-Token') or query.get('api_key')
        if not supplied:
            match = re.search(r'Token="([^"]+)"', self.headers.get('Authorization', ''))
            supplied = match[1] if match else None
        if conditions['expired'] or supplied != token:
            self.reply({'Error': 'synthetic expired identity'}, 401)
            return False
        return True

    def page(self, identifiers, query, raw=False):
        if conditions['empty']:
            identifiers = []
        term = query.get('searchterm', '').casefold()
        kinds = query.get('includeitemtypes', '').split(',')
        identifiers = [key for key in identifiers if (not term or term in items[key]['Name'].casefold())
                       and (kinds == [''] or items[key]['Type'] in kinds)]
        if query.get('sortorder') == 'Descending':
            identifiers.reverse()
        if conditions['catalog_delay_ms']:
            time.sleep(conditions['catalog_delay_ms'] / 1000)
        start = int(query.get('startindex', 0))
        limit = int(query.get('limit', 50))
        values = [item(key) for key in identifiers[start:start + limit]]
        self.reply(values if raw else {'Items': values, 'TotalRecordCount': len(identifiers)})

    def serve_media(self, filename):
        if conditions['media_fail']:
            self.reply({'Error': 'synthetic media failure'}, 503)
            return
        if filename.endswith(('.srt', '.vtt')) and conditions['subtitle_delay_ms']:
            time.sleep(conditions['subtitle_delay_ms'] / 1000)
        target = (media / filename).resolve()
        if not target.is_relative_to(media) or not target.is_file():
            self.reply({'Error': 'missing synthetic media'}, 404)
            return
        size = target.stat().st_size
        start, end = 0, size - 1
        match = re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers.get('Range', ''))
        if match:
            start = int(match[1])
            end = min(end, int(match[2])) if match[2] else end
        if start > end:
            self.send_response(416)
            self.send_header('Content-Range', f'bytes */{size}')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        self.send_response(206 if match else 200)
        self.send_header('Content-Type', 'application/vnd.apple.mpegurl' if target.suffix == '.m3u8' else mimetypes.guess_type(target)[0] or 'application/octet-stream')
        self.send_header('Content-Length', str(end - start + 1))
        self.send_header('Accept-Ranges', 'bytes')
        if match:
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.end_headers()
        try:
            with target.open('rb') as stream:
                stream.seek(start)
                remaining = end - start + 1
                while remaining:
                    data = stream.read(min(remaining, 65536))
                    if not data:
                        break
                    self.wfile.write(data)
                    remaining -= len(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        path, query = self.parsed()
        if path == '/__state':
            with lock:
                state = {'conditions': dict(conditions), 'request_count': len(requests),
                         'report_count': len(reports), 'reports': reports[-40:], 'requests': requests[-80:]}
            self.reply(state)
            return
        if path == '/System/Info/Public':
            self.reply({'Id': f'mobile-fixture-server-{args.port}', 'ServerName': 'Rillight 合成服务器', 'Version': '4.9.0'})
            return
        if not self.authorized(query):
            return
        if path == '/Users/mobile-user':
            self.reply(user)
        elif path.endswith('/Views'):
            self.reply({'Items': views, 'TotalRecordCount': len(views)})
        elif path.startswith('/media/'):
            self.serve_media(path.removeprefix('/media/'))
        elif '/Subtitles/' in path:
            self.serve_media('sample.' + path.rsplit('.', 1)[-1])
        elif '/Images/' in path:
            self.reply(poster(path.split('/')[2], '/Backdrop' in path or '/Thumb' in path), mime='image/png')
        elif path.endswith('/Items/Resume'):
            self.page([key for key in items if positions.get(key, 0) > 0], query)
        elif path == '/Shows/NextUp':
            self.page([key for key in items if key.endswith('episode-2')], query)
        elif path.endswith('/Items/Latest'):
            parent = query.get('parentid', 'movies')
            self.page([key for key, value in items.items() if value.get('ParentId') == parent], query, raw=True)
        elif path.endswith('/Similar'):
            self.page([key for key in items if key.startswith('movie-')][:8], query)
        elif re.fullmatch(r'/Users/mobile-user/Items/[^/]+', path):
            identifier = path.rsplit('/', 1)[-1]
            self.reply(item(identifier) if identifier in items else {}, 200 if identifier in items else 404)
        elif path.endswith('/Items') or path in ('/Items', '/Search/Hints') or path.startswith('/Shows/'):
            parent = query.get('parentid')
            match = re.fullmatch(r'/Shows/([^/]+)/(Seasons|Episodes)', path)
            if match:
                parent = query.get('seasonid', match[1])
                query['includeitemtypes'] = 'Season' if match[2] == 'Seasons' else 'Episode'
            identifiers = list(items)
            if parent:
                identifiers = [key for key in identifiers if items[key].get('ParentId') == parent
                               or (query.get('recursive') == 'true' and items[key].get('SeriesId') == parent)]
            self.page(identifiers, query)
        else:
            self.reply({'Items': [], 'TotalRecordCount': 0})

    def do_POST(self):
        path, query = self.parsed()
        body = self.body()
        if path == '/__control':
            with lock:
                for key, value in body.items():
                    if key in conditions:
                        conditions[key] = value
            self.reply(conditions)
            return
        if path.endswith('/AuthenticateByName'):
            if conditions['offline']:
                self.reply({'Error': 'synthetic network outage'}, 503)
            elif conditions['auth_fail'] or body.get('Username', body.get('username')) != 'mobile' or body.get('Pw', body.get('Password', '')) != 'test-only':
                self.reply({'Error': 'synthetic invalid credentials'}, 401)
            else:
                conditions['expired'] = False
                self.reply({'AccessToken': token, 'User': user, 'ServerId': f'mobile-fixture-server-{args.port}'})
            return
        if not self.authorized(query):
            return
        if path.endswith('/PlaybackInfo'):
            identifier = path.split('/')[-2]
            self.reply({'PlaySessionId': identifier + '-session', 'MediaSources': [] if identifier == 'no-media'
                        else [source(identifier, body.get('EnableDirectPlay') is False)]})
        elif path.startswith('/Sessions/Playing'):
            event = {'path': path, 'body': body, 'time': time.time(), 'accepted': not conditions['report_fail']}
            with lock:
                event['sequence'] = len(reports) + 1
                reports.append(event)
                with (output / 'reports.jsonl').open('a', encoding='utf-8') as stream:
                    stream.write(json.dumps(event) + '\n')
            if conditions['report_fail']:
                self.reply({'Error': 'synthetic report failure'}, 503)
            else:
                if body.get('ItemId') in items:
                    positions[body['ItemId']] = int(body.get('PositionTicks', 0))
                self.reply({})
        elif '/PlayedItems/' in path:
            played.add(path.rsplit('/', 1)[-1])
            self.reply({})
        else:
            self.reply({})

    def do_DELETE(self):
        path, query = self.parsed()
        if not self.authorized(query):
            return
        if '/PlayedItems/' in path:
            played.discard(path.rsplit('/', 1)[-1])
        self.reply({})


server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
(output / 'server.json').write_text(json.dumps({'url': f'http://127.0.0.1:{args.port}',
    'username': 'mobile', 'password': 'test-only', 'synthetic': True}), encoding='utf-8')
print(f'Synthetic mobile Emby ready on 127.0.0.1:{args.port}', flush=True)
server.serve_forever()


