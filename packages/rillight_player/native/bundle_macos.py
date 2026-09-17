"""Run from Runner's final build phase, before app signing.

Usage: python3 bundle_macos.py path/to/Rillight.app
Copies the complete locked dependency closure; no host Homebrew paths remain.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys

from prepare_macos import ROOT, MANIFEST, prepare, verified

def otool_dependencies(output):
    # Both thin and fat Mach-O outputs contain file/architecture titles. Only
    # LC_LOAD_DYLIB/LC_ID_DYLIB records carry a compatibility-version field.
    return [line.strip().split(' (', 1)[0] for line in output.splitlines()
            if ' (compatibility version ' in line]


def bundle(app_path):
    prepare()
    app = Path(app_path).resolve()
    if app.suffix != '.app' or not (app / 'Contents').is_dir():
        raise RuntimeError('Expected an existing .app bundle')
    destination = app / 'Contents/Frameworks'
    destination.mkdir(exist_ok=True)
    names = {entry['name'] for entry in MANIFEST['macos']['files']}
    for entry in MANIFEST['macos']['files']:
        source = ROOT / 'macos/Libraries' / entry['name']
        if not verified(source, entry):
            raise RuntimeError('Changed native input: ' + entry['name'])
        target = destination / entry['name']
        shutil.copyfile(source, target)
        output = subprocess.check_output(['otool', '-L', str(target)], text=True)
        for dependency in otool_dependencies(output):
            if dependency.startswith('@rpath/') and Path(dependency).name not in names:
                raise RuntimeError('Unbundled native dependency: ' + dependency)
            if dependency.startswith(('/opt/', '/usr/local/', '/Users/')):
                raise RuntimeError('Nonportable native dependency: ' + dependency)
        identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY', '') or '-'
        subprocess.check_call(['codesign', '--force', '--sign', identity, '--timestamp=none', str(target)])
    resources = app / 'Contents/Resources'
    resources.mkdir(exist_ok=True)
    shutil.copyfile(ROOT / 'native/dependencies.json', resources / 'rillight-native-dependencies.json')
    shutil.copyfile(ROOT / 'THIRD_PARTY_NOTICES.md', resources / 'rillight-native-notices.md')
    shutil.copytree(ROOT / 'native/licenses', resources / 'rillight-native-licenses', dirs_exist_ok=True)
    print('Bundled and signed', len(names), 'locked universal dylibs')

if __name__ == '__main__':
    bundle(sys.argv[1])
