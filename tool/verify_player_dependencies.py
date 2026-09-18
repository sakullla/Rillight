"""Verify production dependency removal and the actual bundled libmpv version."""
import json
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
for path in [root / 'pubspec.yaml', root / 'pubspec.lock',
             *root.glob('lib/**/*.dart'), *root.glob('windows/flutter/generated*'),
             *root.glob('linux/flutter/generated*'), *root.glob('macos/Flutter/Generated*')]:
    text = path.read_text(encoding='utf-8')
    if re.search(r'media_kit|desktop_multi_window', text):
        raise RuntimeError(f'Retired playback dependency remains in {path.relative_to(root)}')
    if path.name == 'generated_plugins.cmake' and re.search(r'^\s*jni\s*$', text, re.M):
        raise RuntimeError(f'Desktop plugin list must not include the Android jni FFI plugin: {path.relative_to(root)}')
manifest = json.loads((root / 'packages/rillight_player/native/dependencies.json').read_text())
for name in ['mpv', 'angle']:
    if not re.fullmatch('[a-f0-9]{64}', manifest['windows'][name]['sha256']):
        raise RuntimeError('Missing pinned native archive hash')
bundle = root / 'build/windows/x64/runner/Release'
if sys.platform == 'win32' and (bundle / 'rillight.exe').exists():
    for filename in ['media_kit_video_plugin.dll', 'media_kit_libs_windows_video_plugin.dll',
                     'desktop_multi_window_plugin.dll']:
        if (bundle / filename).exists():
            raise RuntimeError(f'Retired binary in output: {filename}')
    for filename in ['libmpv-2.dll', 'rillight_player_plugin.dll', 'libEGL.dll', 'libGLESv2.dll',
                     'data/rillight_player/dependencies.json', 'data/rillight_player/THIRD_PARTY_NOTICES.md']:
        if not (bundle / filename).is_file():
            raise RuntimeError(f'Missing packaged runtime: {filename}')
    output = subprocess.check_output([sys.executable,
        str(root / 'packages/rillight_player/native/check_mpv.py'), str(bundle / 'libmpv-2.dll')], text=True)
    versions = json.loads(output)
    expected = manifest['windows']['mpv']
    if expected['version'] not in versions['mpv-version'] or expected['ffmpeg'] not in versions['ffmpeg-version']:
        raise RuntimeError(f'Loaded runtime differs from pinned manifest: {versions}')
    print(json.dumps(versions))
print('Production dependencies and available native bundle verified.')
