"""Verify retired player removal and the pinned Windows owned-core bundle."""

import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
SPEC = json.loads((ROOT / 'packages/rillight_player/native/core_dependencies.json').read_text())


def sha256(path: Path) -> str:
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


for path in [ROOT / 'pubspec.yaml', ROOT / 'pubspec.lock',
             *ROOT.glob('lib/**/*.dart'), *ROOT.glob('windows/flutter/generated*'),
             *ROOT.glob('linux/flutter/generated*'),
             *ROOT.glob('macos/Flutter/Generated*')]:
    if not path.is_file():
        continue
    content = path.read_text(encoding='utf-8')
    if re.search(r'media_kit|desktop_multi_window', content):
        raise RuntimeError(f'Retired playback dependency remains in {path.relative_to(ROOT)}')
    if path.name == 'generated_plugins.cmake' and re.search(r'^\s*jni\s*$', content, re.M):
        raise RuntimeError(f'Desktop plugin list includes Android jni: {path.relative_to(ROOT)}')

bundle = ROOT / 'build/windows/x64/runner/Release'
if sys.platform == 'win32':
    if not (bundle / 'rillight.exe').is_file():
        raise RuntimeError('Windows release bundle is missing')
    for name in ('libmpv-2.dll', 'media_kit_video_plugin.dll',
                 'media_kit_libs_windows_video_plugin.dll',
                 'desktop_multi_window_plugin.dll'):
        if (bundle / name).exists():
            raise RuntimeError(f'Retired binary remains in output: {name}')
    marker_file = bundle / 'data/rillight_player/rillight-core-dependencies.json'
    core = bundle / 'librillight_core.dll'
    for path in (marker_file, core, bundle / 'rillight_player_plugin.dll',
                 bundle / 'data/rillight_player/core_dependencies.json',
                 bundle / 'data/rillight_player/THIRD_PARTY_NOTICES.md'):
        if not path.is_file():
            raise RuntimeError(f'Missing packaged runtime: {path.relative_to(bundle)}')
    notices = bundle / 'data/rillight_player'
    if sha256(notices / 'core_dependencies.json') != sha256(
            ROOT / 'packages/rillight_player/native/core_dependencies.json') or \
            sha256(notices / 'THIRD_PARTY_NOTICES.md') != sha256(
                ROOT / 'packages/rillight_player/THIRD_PARTY_NOTICES.md'):
        raise RuntimeError('Bundled Windows source lock or notices are stale')
    source_licenses = ROOT / 'packages/rillight_player/native/licenses'
    bundled_licenses = notices / 'licenses'
    expected_licenses = {path.name: sha256(path) for path in source_licenses.iterdir()
                         if path.is_file()}
    actual_licenses = {path.name: sha256(path) for path in bundled_licenses.iterdir()
                       if path.is_file()} if bundled_licenses.is_dir() else {}
    if actual_licenses != expected_licenses:
        raise RuntimeError('Bundled Windows native license set differs from source')
    marker = json.loads(marker_file.read_text(encoding='utf-8'))
    if (marker.get('platform') != 'windows-x64' or
            marker.get('ffmpeg_version') != SPEC['ffmpeg']['version'] or
            marker.get('ffmpeg_commit') != SPEC['ffmpeg']['commit'] or
            marker.get('ffmpeg_patches') != SPEC['ffmpeg']['patches'] or
            marker.get('libass', {}).get('commit') != SPEC['libass']['commit'] or
            marker.get('dav1d', {}).get('commit') != SPEC['dav1d']['commit']):
        raise RuntimeError('Bundled Windows core provenance differs from pin')
    for relative, expected in marker['libraries'].items():
        if not relative.startswith('bin/'):
            continue
        path = bundle / Path(relative).name
        if not path.is_file() or sha256(path) != expected:
            raise RuntimeError(f'Missing or changed bundled DLL: {relative}')
    with os.add_dll_directory(str(bundle)):
        library = ctypes.WinDLL(str(core))
        library.rillight_core_abi_version.restype = ctypes.c_uint32
        library.rillight_core_ffmpeg_versions.restype = ctypes.c_char_p
        abi = library.rillight_core_abi_version()
        versions = library.rillight_core_ffmpeg_versions().decode('ascii')
    header = (ROOT / 'packages/rillight_player/native/core/rillight_core.h').read_text()
    expected_abi = int(re.search(r'#define RILLIGHT_CORE_ABI_VERSION (\d+)', header).group(1))
    if abi != expected_abi or not versions.startswith(
            'ffmpeg=' + SPEC['ffmpeg']['version'].removeprefix('n') + ';'):
        raise RuntimeError(f'Loaded Windows core/version mismatch: ABI {abi}, {versions}')
    print(json.dumps({'coreAbi': abi, 'versions': versions}, sort_keys=True))
else:
    print('Non-Windows host: static dependency scan only')
print('Retired player dependencies and available core bundle verified.')
