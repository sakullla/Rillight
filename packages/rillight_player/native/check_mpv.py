"""Check the loaded library version; pkg-config's version is only its C API."""
import ctypes
import json
from pathlib import Path
import re
import sys

library = ctypes.CDLL(sys.argv[1])
library.mpv_client_api_version.restype = ctypes.c_ulong
library.mpv_create.restype = ctypes.c_void_p
library.mpv_set_option_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
library.mpv_initialize.argtypes = [ctypes.c_void_p]
library.mpv_get_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
library.mpv_get_property_string.restype = ctypes.c_void_p
library.mpv_free.argtypes = [ctypes.c_void_p]
library.mpv_terminate_destroy.argtypes = [ctypes.c_void_p]
player = library.mpv_create()
if not player:
    raise RuntimeError('mpv_create failed')
try:
    for name, value in [(b'vo', b'null'), (b'ao', b'null'), (b'terminal', b'no')]:
        if library.mpv_set_option_string(player, name, value) < 0:
            raise RuntimeError('Initialization option failed')
    if library.mpv_initialize(player) < 0:
        raise RuntimeError('mpv_initialize failed')
    result = {'client_api': hex(library.mpv_client_api_version())}
    for name in ['mpv-version', 'ffmpeg-version']:
        pointer = library.mpv_get_property_string(player, name.encode())
        if not pointer:
            raise RuntimeError('Missing property: ' + name)
        result[name] = ctypes.string_at(pointer).decode()
        library.mpv_free(pointer)
    print(json.dumps(result))
    match = re.search(r'(\d+)\.(\d+)\.(\d+)', result['mpv-version'])
    if not match or tuple(map(int, match.groups())) < (0, 41, 0):
        raise RuntimeError('mpv 0.41.0 or newer is required')
    ffmpeg = result['ffmpeg-version']
    release = re.search(r'(\d+)\.(\d+)\.(\d+)', ffmpeg)
    manifest = json.loads((Path(__file__).parent / 'dependencies.json').read_text())
    pinned_git = manifest['windows']['mpv']['ffmpeg']
    if not ((release and tuple(map(int, release.groups())) >= (9, 0, 1)) or ffmpeg == pinned_git):
        raise RuntimeError(f'FFmpeg 9.0.1 or the locked newer git build is required; loaded {ffmpeg}')
finally:
    library.mpv_terminate_destroy(player)
