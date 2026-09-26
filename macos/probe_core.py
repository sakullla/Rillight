"""Load the packaged owned core and report actual FFmpeg ABI/library paths.

Set DYLD_LIBRARY_PATH to the application's Contents/Frameworks before starting
Python so dyld resolves every @rpath dependency from the release candidate.
"""

import argparse
import ctypes
import json
from pathlib import Path

from verify_bundle import verify


def loaded_images() -> set[Path]:
    process = ctypes.CDLL(None)
    count = process._dyld_image_count
    count.restype = ctypes.c_uint32
    name = process._dyld_get_image_name
    name.argtypes = [ctypes.c_uint32]
    name.restype = ctypes.c_char_p
    return {Path(raw.decode()).resolve() for index in range(count())
            if (raw := name(index))}


def probe(app_path: Path) -> dict:
    app = Path(app_path).resolve()
    record = verify(app)
    frameworks = app / 'Contents/Frameworks'
    core_path = frameworks / 'librillight_core.dylib'
    library = ctypes.CDLL(str(core_path))
    abi = library.rillight_core_abi_version
    abi.restype = ctypes.c_uint32
    abi.argtypes = []
    versions = library.rillight_core_ffmpeg_versions
    versions.restype = ctypes.c_char_p
    versions.argtypes = []
    actual_abi = abi()
    actual_versions = versions().decode()
    parsed = dict(piece.split('=', 1) for piece in actual_versions.split(';')
                  if '=' in piece)
    if actual_abi != record['core_abi'] or \
       parsed.get('ffmpeg', '').lstrip('n') != record['ffmpeg_version'].lstrip('n'):
        raise RuntimeError('Loaded core ABI/FFmpeg version differs from pinned manifest')
    images = loaded_images()
    required = ('rillight_core', 'avformat', 'avcodec', 'avutil',
                'avfilter', 'swresample', 'swscale', 'ass')
    for component in required:
        matches = [name for name in record['libraries']
                   if name.startswith(f'lib{component}.')]
        if not matches or all((frameworks / name).resolve() not in images
                              for name in matches):
            raise RuntimeError(f'Packaged lib{component} was not loaded by dyld')
    return {
        'core_abi': actual_abi,
        'ffmpeg_versions': parsed,
        'ffmpeg_source_commit': record['ffmpeg_commit'],
        'libraries': {name: {
            'path': str((frameworks / name).resolve()),
            'loaded': (frameworks / name).resolve() in images,
            'bundle_sha256': record['bundled_libraries_sha256'][name],
            'sdk_sha256': source_hash,
        } for name, source_hash in record['libraries'].items()},
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app')
    args = parser.parse_args()
    print(json.dumps(probe(Path(args.app)), ensure_ascii=False,
                     sort_keys=True, indent=2))
