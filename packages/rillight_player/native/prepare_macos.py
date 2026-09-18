"""Prepare live IINA universal dylibs and the SHA256-locked mpv 0.41 headers."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = json.loads((ROOT / 'native/dependencies.json').read_text())
USER_AGENT = 'Rillight/1.0 (+https://github.com/sakullla/Rillight)'
DYLIBS_URL = MANIFEST['macos']['dylibs_url'].rstrip('/')
FILELIST_URL = MANIFEST['macos'].get('filelist_url', DYLIBS_URL + '/filelist.txt')
FAT_MAGIC = b'\xca\xfe\xba\xbe'
DYLIB_NAME = re.compile(r'^[A-Za-z0-9._-]+\.dylib$')


def verified(path, entry):
    return path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == entry['sha256']


def is_universal_dylib(path):
    if not path.is_file():
        return False
    header = path.read_bytes()[:8]
    if len(header) < 8 or header[:4] != FAT_MAGIC:
        return False
    return 2 <= int.from_bytes(header[4:8], 'big') <= 16


def download(url, destination, extra_headers=None):
    headers = {'User-Agent': USER_AGENT, 'Accept': '*/*'}
    if extra_headers:
        headers.update(extra_headers)
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request) as response, Path(destination).open('wb') as output:
        shutil.copyfileobj(response, output)
        return getattr(response, 'headers', {})


def fetch_text(url):
    request = urllib.request.Request(url, headers={'User-Agent': USER_AGENT, 'Accept': '*/*'})
    with urllib.request.urlopen(request) as response:
        return response.read().decode('utf-8')


def parse_filelist(text):
    names = []
    seen = set()
    for line in text.splitlines():
        name = line.strip()
        if not name or name.startswith('#'):
            continue
        if not DYLIB_NAME.fullmatch(name):
            raise RuntimeError('Invalid IINA file list entry: ' + name)
        if name in seen:
            continue
        seen.add(name)
        names.append(name)
    if 'libmpv.2.dylib' not in seen:
        raise RuntimeError('IINA file list is missing libmpv.2.dylib')
    return names


def _cache_headers(meta_path):
    if not meta_path.is_file():
        return {}
    meta = json.loads(meta_path.read_text())
    headers = {}
    if meta.get('etag'):
        headers['If-None-Match'] = meta['etag']
    elif meta.get('last_modified'):
        headers['If-Modified-Since'] = meta['last_modified']
    return headers


def prepare_dylibs():
    destination = ROOT / 'macos/Libraries'
    destination.mkdir(parents=True, exist_ok=True)
    cache = Path(os.environ.get('RILLIGHT_NATIVE_CACHE', str(ROOT / 'macos/.cache')))
    cache.mkdir(parents=True, exist_ok=True)
    names = parse_filelist(fetch_text(FILELIST_URL))
    for name in names:
        url = f'{DYLIBS_URL}/{name}'
        target = destination / name
        cached = cache / name
        meta_path = cache / (name + '.meta')
        temporary = cache / (name + '.download')
        try:
            headers = download(url, temporary, _cache_headers(meta_path) if cached.is_file() else None)
            if not is_universal_dylib(temporary):
                raise RuntimeError('macOS native download is not a universal Mach-O: ' + name)
            temporary.replace(cached)
            meta_path.write_text(json.dumps({
                'etag': headers.get('ETag'),
                'last_modified': headers.get('Last-Modified'),
            }))
        except urllib.error.HTTPError as error:
            if error.code != 304 or not is_universal_dylib(cached):
                raise
        finally:
            if temporary.exists():
                temporary.unlink()
        shutil.copyfile(cached, target)
    wanted = set(names)
    for path in destination.glob('*.dylib'):
        if path.name not in wanted:
            path.unlink()


def prepare_headers():
    headers = ROOT / 'macos/Headers/mpv'
    headers.mkdir(parents=True, exist_ok=True)
    for entry in MANIFEST['headers']:
        source = ROOT / 'native/include/mpv' / entry['name']
        if not verified(source, entry):
            raise RuntimeError('libmpv header SHA256 mismatch: ' + entry['name'])
        shutil.copyfile(source, headers / entry['name'])


def prepare():
    prepare_dylibs()
    prepare_headers()


if __name__ == '__main__':
    prepare()
