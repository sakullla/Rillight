"""Prepare SHA256-locked IINA universal dylibs and the mpv 0.41 headers."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = json.loads((ROOT / 'native/dependencies.json').read_text())
USER_AGENT = 'Rillight/1.0 (+https://github.com/sakullla/Rillight)'


def verified(path, entry):
    return path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == entry['sha256']


def download(url, destination):
    request = urllib.request.Request(url, headers={'User-Agent': USER_AGENT, 'Accept': '*/*'})
    with urllib.request.urlopen(request) as response, Path(destination).open('wb') as output:
        shutil.copyfileobj(response, output)


def prepare():
    destination = ROOT / 'macos/Libraries'
    destination.mkdir(parents=True, exist_ok=True)
    cache = Path(os.environ.get('RILLIGHT_NATIVE_CACHE', str(ROOT / 'macos/.cache')))
    cache.mkdir(parents=True, exist_ok=True)
    for entry in MANIFEST['macos']['files']:
        target = destination / entry['name']
        if verified(target, entry):
            continue
        cached = cache / entry['name']
        if not cached.exists():
            temporary = cached.with_suffix('.download')
            download(entry['url'], temporary)
            if not verified(temporary, entry):
                raise RuntimeError('macOS native download SHA256 mismatch: ' + entry['name'])
            temporary.replace(cached)
        if not verified(cached, entry):
            raise RuntimeError('macOS native cache SHA256 mismatch: ' + entry['name'])
        shutil.copyfile(cached, target)
    headers = ROOT / 'macos/Headers/mpv'
    headers.mkdir(parents=True, exist_ok=True)
    for entry in MANIFEST['headers']:
        source = ROOT / 'native/include/mpv' / entry['name']
        if not verified(source, entry):
            raise RuntimeError('libmpv header SHA256 mismatch: ' + entry['name'])
        shutil.copyfile(source, headers / entry['name'])


if __name__ == '__main__':
    prepare()
