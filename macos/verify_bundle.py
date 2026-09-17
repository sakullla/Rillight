"""Audit the built macOS application's dylib closure before final signing."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'packages/rillight_player/native'))
from bundle_macos import otool_dependencies

def verify(app_path, *, signed=False):
    app = Path(app_path).resolve()
    frameworks = app / 'Contents/Frameworks'
    manifest = json.loads((app / 'Contents/Resources/rillight-native-dependencies.json').read_text())
    with (app / 'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    minimum = tuple(map(int, info['LSMinimumSystemVersion'].split('.')))
    if minimum < (12, 0):
        raise RuntimeError('Flutter 3.47.4 requires the application minimum to be macOS 12')
    for entry in manifest['macos']['files']:
        library = frameworks / entry['name']
        if not library.is_file():
            raise RuntimeError('Missing locked dylib: ' + entry['name'])
        architectures = subprocess.check_output(['lipo', '-archs', str(library)], text=True).split()
        if not {'x86_64', 'arm64'}.issubset(architectures):
            raise RuntimeError('Locked dylib is not universal: ' + entry['name'])
    binaries = [app / 'Contents/MacOS' / info['CFBundleExecutable'], *frameworks.glob('*.dylib')]
    for framework in frameworks.glob('*.framework'):
        binary = framework / framework.stem
        if binary.is_file():
            binaries.append(binary)
    for binary in binaries:
        output = subprocess.check_output(['otool', '-L', str(binary)], text=True)
        for dependency in otool_dependencies(output):
            if dependency.startswith('@rpath/'):
                if not (frameworks / dependency.removeprefix('@rpath/')).exists():
                    raise RuntimeError(f'{binary.name}: unbundled {dependency}')
            elif dependency.startswith('@loader_path/'):
                if not (binary.parent / dependency.removeprefix('@loader_path/')).exists():
                    raise RuntimeError(f'{binary.name}: missing loader-relative {dependency}')
            elif dependency.startswith('@executable_path/'):
                if not (binaries[0].parent / dependency.removeprefix('@executable_path/')).exists():
                    raise RuntimeError(f'{binary.name}: missing executable-relative {dependency}')
            elif dependency.startswith('/') and not dependency.startswith(('/System/Library/', '/usr/lib/')):
                raise RuntimeError(f'{binary.name}: build-machine path {dependency}')
    main = binaries[0]
    commands = subprocess.check_output(['otool', '-l', str(main)], text=True)
    if 'path @executable_path/../Frameworks ' not in commands:
        raise RuntimeError('Application is missing its private Frameworks runpath')
    print(f'Checked {len(binaries)} Mach-O binaries and {len(manifest["macos"]["files"])} locked universal dylibs')
    if signed:
        from sign_bundle import release_entitlements, verify_signed_entitlements
        verify_signed_entitlements(app, release_entitlements())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app')
    parser.add_argument('--signed', action='store_true', help='Verify actual final Release entitlements')
    args = parser.parse_args()
    verify(args.app, signed=args.signed)
