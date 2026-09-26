"""Audit the owned-core macOS application closure and final signature."""

import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] /
                       'packages/rillight_player/native'))
from bundle_macos import NATIVE_LICENSES, audit_binary
from prepare_macos import REQUIRED, digest


def deployment_versions(output: str) -> list[tuple[int, ...]]:
    versions = []
    command = None
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith('cmd LC_'):
            command = stripped.removeprefix('cmd ')
        if command == 'LC_BUILD_VERSION':
            match = re.fullmatch(r'minos (\d+(?:\.\d+)+)', stripped)
        elif command == 'LC_VERSION_MIN_MACOSX':
            match = re.fullmatch(r'version (\d+(?:\.\d+)+)', stripped)
        else:
            match = None
        if match:
            versions.append(tuple(int(piece) for piece in match.group(1).split('.')))
            command = None
    return versions


def verify(app_path, *, signed=False):
    app = Path(app_path).resolve()
    contents = app / 'Contents'
    frameworks = contents / 'Frameworks'
    resources = contents / 'Resources'
    with (contents / 'Info.plist').open('rb') as source:
        info = plistlib.load(source)
    minimum = tuple(map(int, info['LSMinimumSystemVersion'].split('.')))
    if minimum < (12, 0):
        raise RuntimeError('Flutter 3.47.4 requires macOS 12 or newer')
    record_path = resources / 'rillight-macos-closure.json'
    source_lock_path = resources / 'rillight-core-source-lock.json'
    sdk_marker_path = resources / 'rillight-core-dependencies.json'
    if not all(path.is_file() for path in (record_path, source_lock_path,
                                            sdk_marker_path)):
        raise RuntimeError('Missing bundled owned-core provenance records')
    record = json.loads(record_path.read_text(encoding='utf-8'))
    source_lock = json.loads(source_lock_path.read_text(encoding='utf-8'))
    sdk_marker = json.loads(sdk_marker_path.read_text(encoding='utf-8'))
    if record.get('schema') != 1 or record.get('target') != 'macos-universal':
        raise RuntimeError('Unexpected macOS native closure schema or target')
    if record.get('core_spec_sha256') != digest(source_lock_path) or \
       record.get('sdk_marker_sha256') != digest(sdk_marker_path):
        raise RuntimeError('Bundled macOS source/SDK provenance hash mismatch')
    ffmpeg = source_lock['ffmpeg']
    if (record.get('ffmpeg_version') != ffmpeg['version'] or
            record.get('ffmpeg_commit') != ffmpeg['commit'] or
            record.get('ffmpeg_tag') != ffmpeg['version'] or
            record.get('ffmpeg_patches') != ffmpeg['patches'] or
            sdk_marker.get('platform') != 'macos-universal' or
            sdk_marker.get('ffmpeg_commit') != ffmpeg['commit'] or
            sdk_marker.get('ffmpeg_version') != ffmpeg['version'] or
            record.get('libass_version') != source_lock['libass']['version'] or
            record.get('libass_commit') != source_lock['libass']['commit']):
        raise RuntimeError('macOS native source pin differs from bundle record')
    libraries = record.get('libraries')
    output_hashes = record.get('final_libraries_sha256' if signed else
                               'bundled_libraries_sha256')
    if not isinstance(libraries, dict) or not isinstance(output_hashes, dict) or \
       set(libraries) != set(output_hashes) or \
       'librillight_core.dylib' not in libraries:
        raise RuntimeError('Incomplete owned-core macOS library hash record')
    for component in REQUIRED:
        if not any(name.startswith(f'lib{component}.') for name in libraries):
            raise RuntimeError('Missing required macOS core component: ' + component)
    if any('mpv' in name.lower() for name in libraries):
        raise RuntimeError('Legacy libmpv appears in core manifest')
    if any('mpv' in path.name.lower() for path in frameworks.glob('*.dylib')):
        raise RuntimeError('Legacy libmpv appears in application bundle')
    sdk_libraries = sdk_marker.get('libraries', {})
    libass = sdk_marker.get('libass', {})
    if not isinstance(sdk_libraries, dict) or not isinstance(libass, dict):
        raise RuntimeError('Bundled SDK marker lacks component library hashes')
    sdk_hashes = {Path(path).name: sha for path, sha in sdk_libraries.items()
                  if Path(path).name.endswith('.dylib')}
    if isinstance(libass.get('library'), str):
        sdk_hashes[Path(libass['library']).name] = libass.get('sha256')
    dav1d = sdk_marker.get('dav1d', {})
    if isinstance(dav1d, dict) and isinstance(dav1d.get('library'), str):
        sdk_hashes[Path(dav1d['library']).name] = dav1d.get('sha256')
    for name, source_hash in libraries.items():
        if name != 'librillight_core.dylib' and sdk_hashes.get(name) != source_hash:
            raise RuntimeError('Bundled source hash differs from SDK marker: ' + name)
    for name, expected in output_hashes.items():
        if Path(name).name != name or not name.endswith('.dylib'):
            raise RuntimeError('Invalid native dylib name in closure record')
        library = frameworks / name
        if not library.is_file() or digest(library) != expected:
            raise RuntimeError('Bundled dylib hash mismatch: ' + name)
        architectures = subprocess.check_output(
            ['lipo', '-archs', str(library)], text=True).split()
        if not {'x86_64', 'arm64'}.issubset(architectures):
            raise RuntimeError('Bundled dylib is not universal: ' + name)
        versions = deployment_versions(subprocess.check_output(
            ['otool', '-l', str(library)], text=True))
        if not versions or any((version + (0, 0))[:2] > (12, 0)
                               for version in versions):
            raise RuntimeError('Bundled dylib exceeds macOS 12 deployment: ' + name)
    for name in NATIVE_LICENSES:
        if not (resources / 'rillight-native-licenses' / name).is_file():
            raise RuntimeError('Missing bundled native license: ' + name)
    if not (resources / 'rillight-native-notices.md').is_file():
        raise RuntimeError('Missing native third-party notices')
    executable = contents / 'MacOS' / info['CFBundleExecutable']
    binaries = [executable, *(frameworks / name for name in libraries)]
    for framework in frameworks.glob('*.framework'):
        binary = framework / framework.stem
        if binary.is_file():
            binaries.append(binary)
    for binary in binaries:
        audit_binary(binary, contents)
    commands = subprocess.check_output(['otool', '-l', str(executable)], text=True)
    executable_versions = deployment_versions(commands)
    if not executable_versions or any((version + (0, 0))[:2] > (12, 0)
                                      for version in executable_versions):
        raise RuntimeError('Application executable exceeds macOS 12 deployment')
    if 'path @executable_path/../Frameworks ' not in commands:
        raise RuntimeError('Application is missing its private Frameworks runpath')
    print(f'Checked {len(binaries)} Mach-O binaries and {len(libraries)} '
          'hash-verified universal core dylibs')
    if signed:
        from sign_bundle import release_entitlements, verify_signed_entitlements
        verify_signed_entitlements(app, release_entitlements())
        subprocess.check_call(['codesign', '--verify', '--deep', '--strict', str(app)])
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app')
    parser.add_argument('--signed', action='store_true',
                        help='Verify final release hashes, signature and entitlements')
    args = parser.parse_args()
    verify(args.app, signed=args.signed)
