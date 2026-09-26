"""Build/verify the relocatable Linux bundle and Debian installer.

Static ELF parsing works on any host, including on the original issue #1 deb.
Runtime ldd/packaging/version checks run only on the actual Linux host.
"""
from __future__ import annotations
import argparse
import configparser
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MEDIA = ('librillight_core.so', 'libavcodec.so', 'libavformat.so',
         'libavutil.so', 'libavfilter.so', 'libswresample.so',
         'libswscale.so', 'libass.so', 'libdav1d.so')
VENDORED_SONAMES = ()

def clean_environment():
    return {**{key: value for key, value in os.environ.items()
               if key not in ('LD_LIBRARY_PATH', 'LD_PRELOAD', 'LD_AUDIT')}, 'LC_ALL': 'C'}

def run(args, **kwargs):
    return subprocess.check_output([str(value) for value in args], text=True,
                                   env=clean_environment(), **kwargs)

def elf_dynamic(path):
    """Read PT_DYNAMIC (not section headers) for both ELF classes/endian orders."""
    data = Path(path).read_bytes()
    if not data.startswith(b'\x7fELF'):
        return None
    if len(data) < 52 or data[4] not in (1, 2) or data[5] not in (1, 2):
        raise ValueError(f'{path}: invalid ELF header')
    endian = '<' if data[5] == 1 else '>'
    wide = data[4] == 2
    header = struct.unpack_from(endian + ('16sHHIQQQIHHHHHH' if wide else '16sHHIIIIIHHHHHH'), data)
    loads, dynamic = [], None
    for i in range(header[10]):
        ph = struct.unpack_from(endian + ('IIQQQQQQ' if wide else 'IIIIIIII'),
                                data, header[5] + i * header[9])
        kind = ph[0]
        offset, address, size = (ph[2], ph[3], ph[5]) if wide else (ph[1], ph[2], ph[4])
        if kind == 1:
            loads.append((address, offset, size))
        elif kind == 2:
            dynamic = (offset, size)
    result = {'needed': [], 'soname': None, 'runpath': [], 'rpath': []}
    if dynamic is None:
        return result
    entries = []
    step = 16 if wide else 8
    for offset in range(dynamic[0], dynamic[0] + dynamic[1], step):
        tag, value = struct.unpack_from(endian + ('qQ' if wide else 'iI'), data, offset)
        if tag == 0:
            break
        entries.append((tag, value))
    strings = next((value for tag, value in entries if tag == 5), None)
    if strings is None:
        raise ValueError(f'{path}: missing DT_STRTAB')
    start = next((offset + strings - address for address, offset, size in loads
                  if address <= strings < address + size), None)
    if start is None:
        raise ValueError(f'{path}: unmapped DT_STRTAB')
    for tag, value in entries:
        if tag not in (1, 14, 15, 29):
            continue
        value = data[start + value:data.index(b'\0', start + value)].decode()
        if tag == 1:
            result['needed'].append(value)
        elif tag == 14:
            result['soname'] = value
        else:
            result['runpath' if tag == 29 else 'rpath'] = value.split(':')
    return result

def elf_files(bundle):
    files = {}
    for path in sorted(Path(bundle).rglob('*')):
        if path.is_file():
            if not path.resolve().is_relative_to(Path(bundle).resolve()):
                raise ValueError(f'External bundle symlink: {path}')
            dynamic = elf_dynamic(path)
            if dynamic is not None:
                files[path] = dynamic
    return files

def _must_bundle(name):
    return name.startswith(MEDIA) or name in VENDORED_SONAMES


def expected_runpath(path, bundle):
    relative = os.path.relpath(Path(bundle) / 'lib', path.parent).replace(os.sep, '/')
    return '$ORIGIN' if relative == '.' else '$ORIGIN/' + relative

def verify_entrypoints(bundle, desktop=None):
    wrapper = Path(bundle) / 'rillight-launch'
    if not wrapper.is_file():
        raise ValueError('Missing rillight-launch desktop wrapper')
    if os.name != 'nt' and not os.access(wrapper, os.X_OK):
        raise ValueError('Desktop wrapper is not executable')
    text = wrapper.read_text(encoding='utf-8')
    for contract in ['ldd "$binary"', 'zenity --error', 'launch.log', 'exec "$app_dir/rillight" "$@"']:
        if contract not in text:
            raise ValueError('Missing launcher contract: ' + contract)
    if desktop:
        parser = configparser.ConfigParser(interpolation=None)
        parser.read(desktop, encoding='utf-8')
        entry = parser['Desktop Entry']
        if entry.get('Exec') != '/opt/rillight/rillight-launch' or entry.get('Terminal') != 'false':
            raise ValueError('Desktop entry must use the normal diagnostic wrapper')

def parse_ldd(text):
    if re.search(r'=>\s+not found', text):
        raise ValueError('Unresolved ELF dependency:\n' + text)
    return dict(re.findall(r'^\s*(\S+)\s+=>\s+(/\S+)', text, re.MULTILINE))


def loaded_core_versions(bundle):
    """Load the bundled core from its final RUNPATH, not a development SDK."""
    core = ctypes.CDLL(str(Path(bundle) / 'lib/librillight_core.so'))
    core.rillight_core_abi_version.restype = ctypes.c_uint32
    core.rillight_core_ffmpeg_versions.restype = ctypes.c_char_p
    abi = core.rillight_core_abi_version()
    versions = core.rillight_core_ffmpeg_versions().decode('ascii')
    expected_abi = int(re.search(r'#define RILLIGHT_CORE_ABI_VERSION (\d+)',
                                 (ROOT / 'packages/rillight_player/native/core/rillight_core.h').read_text()).group(1))
    expected_ffmpeg = json.loads((ROOT / 'packages/rillight_player/native/core_dependencies.json').read_text())['ffmpeg']['version'].removeprefix('n')
    actual_ffmpeg, separator, _ = versions.partition(';')
    if (abi != expected_abi or not separator or
            not actual_ffmpeg.startswith('ffmpeg=') or
            actual_ffmpeg.removeprefix('ffmpeg=').removeprefix('n') != expected_ffmpeg):
        raise ValueError(f'Bundled core/version mismatch: ABI {abi}, {versions}')
    return {'coreAbi': abi, 'versions': versions}


def verify_integrity(bundle):
    notices = Path(bundle) / 'data/rillight_player'
    report_file = notices / 'loaded-versions.json'
    marker_file = notices / 'rillight-core-dependencies.json'
    if not report_file.is_file() or not marker_file.is_file():
        raise ValueError('Missing bundled core provenance or loaded-version report')
    report = json.loads(report_file.read_text())
    marker = json.loads(marker_file.read_text())
    spec = json.loads((ROOT / 'packages/rillight_player/native/core_dependencies.json').read_text())
    if (marker.get('platform') != 'linux-x64' or
            marker.get('ffmpeg_version') != spec['ffmpeg']['version'] or
            marker.get('ffmpeg_commit') != spec['ffmpeg']['commit'] or
            marker.get('ffmpeg_patches') != spec['ffmpeg']['patches'] or
            marker.get('libass', {}).get('commit') != spec['libass']['commit'] or
            marker.get('dav1d', {}).get('commit') != spec['dav1d']['commit']):
        raise ValueError('Bundled core source provenance differs from lock')
    hashes = report.get('bundledLibraries')
    if not isinstance(hashes, dict) or not hashes:
        raise ValueError('Missing final bundled library hashes')
    for relative, expected in hashes.items():
        path = (Path(bundle) / relative).resolve()
        if not path.is_relative_to(Path(bundle).resolve()) or not path.is_file():
            raise ValueError(f'Missing/unsafe bundled library: {relative}')
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f'Bundled library SHA256 mismatch: {relative}')
    actual = {str(path.relative_to(bundle)) for path in (Path(bundle) / 'lib').glob('*.so*')
              if path.is_file() and not path.is_symlink()}
    if actual != set(hashes):
        raise ValueError('Bundled library set differs from final hash report')
    if report.get('coreAbi') is None or not str(report.get('versions', '')).startswith('ffmpeg='):
        raise ValueError('Missing actual loaded core version evidence')

def verify_bundle(bundle, *, runtime=True, desktop=None, integrity=True):
    bundle = Path(bundle).resolve()
    files = elf_files(bundle)
    if bundle / 'rillight' not in files:
        raise ValueError('Missing ELF application')
    for path, meta in files.items():
        if 'libmpv' in path.name or any('libmpv' in name for name in meta['needed']):
            raise ValueError(f'{path.name}: retired libmpv must not ship or load')
        expected = expected_runpath(path, bundle)
        if (meta['needed'] or meta['soname']) and (meta['runpath'] != [expected] or meta['rpath']):
            raise ValueError(f'{path.name}: RUNPATH must be {expected}; found {meta["runpath"]}/{meta["rpath"]}')
        for name in meta['needed']:
            if _must_bundle(name) and bundle / 'lib' / name not in files:
                raise ValueError(f'{path.name}: unbundled media dependency {name}')
            if name == 'libjvm.so' or name.startswith('libjawt.so'):
                raise ValueError(f'{path.name}: desktop bundle must not link a JVM')
        if runtime and meta['needed']:
            try:
                resolved = parse_ldd(run(['ldd', path]))
            except ValueError as error:
                raise ValueError(f'{path.name}: {error}') from error
            for name in meta['needed']:
                local = bundle / 'lib' / name
                if local.is_file() and Path(resolved.get(name, '/missing')).resolve() != local.resolve():
                    raise ValueError(f'{path.name}: {name} resolved outside the bundle')
                found = resolved.get(name)
                if found and not (Path(found).resolve().is_relative_to(bundle) or
                                  found.startswith(('/lib/', '/lib64/', '/usr/lib/'))):
                    raise ValueError(f'{path.name}: dependency resolves to build machine: {found}')
    core = bundle / 'lib/librillight_core.so'
    if core not in files or files[core]['soname'] != 'librillight_core.so':
        raise ValueError('Bundled librillight_core.so must have its real SONAME')
    if not any('rillight_player' in path.name and 'librillight_core.so' in meta['needed']
               for path, meta in files.items()):
        raise ValueError('Player plugin must link to bundled librillight_core.so')
    verify_entrypoints(bundle, desktop)
    if integrity:
        verify_integrity(bundle)
    return files

def _host_library(name, files):
    for path, meta in files.items():
        if name not in meta['needed']:
            continue
        found = parse_ldd(run(['ldd', path])).get(name)
        if found:
            return found
    return None


def vendor_sonames(bundle, resolver=None):
    """Copy explicitly listed private SONAMEs when a target requires them."""
    bundle = Path(bundle).resolve()
    libdir = bundle / 'lib'
    libdir.mkdir(parents=True, exist_ok=True)
    files = elf_files(bundle)
    needed = {name for meta in files.values() for name in meta['needed']}
    resolve = resolver or _host_library
    for name in VENDORED_SONAMES:
        if name not in needed or (libdir / name).is_file():
            continue
        source = resolve(name, files)
        if not source:
            raise ValueError(f'Cannot vendor {name}: not found on the build host')
        source = Path(source).resolve()
        if not source.is_file():
            raise ValueError(f'Cannot vendor {name}: {source} is missing')
        copied = libdir / source.name
        shutil.copyfile(source, copied)
        if copied.name != name:
            link = libdir / name
            if link.exists() or link.is_symlink():
                link.unlink()
            os.symlink(copied.name, link)
    return bundle


def prepare_bundle(prefix, bundle):
    prefix, bundle = Path(prefix).resolve(), Path(bundle).resolve()
    if not (prefix / 'rillight-core-dependencies.json').is_file():
        raise ValueError('Use a verified pinned FFmpeg core SDK, not system media libraries')
    native = ROOT / 'packages/rillight_player/native'
    run([sys.executable, ROOT / 'packages/rillight_player/native/bundle_linux.py', prefix, bundle])
    vendor_sonames(bundle)
    for path, meta in elf_files(bundle).items():
        if meta['needed'] or meta['soname']:
            run(['patchelf', '--set-rpath', expected_runpath(path, bundle), path])
    wrapper = bundle / 'rillight-launch'
    shutil.copyfile(ROOT / 'linux/packaging/rillight-launch', wrapper)
    wrapper.chmod(0o755)
    verify_bundle(bundle, integrity=False)
    report = loaded_core_versions(bundle)
    report['bundledLibraries'] = {
        str(path.relative_to(bundle)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted((bundle / 'lib').glob('*.so*')) if path.is_file() and not path.is_symlink()
    }
    (bundle / 'data/rillight_player/loaded-versions.json').write_text(
        json.dumps(report, indent=2, sort_keys=True) + '\n')
    verify_bundle(bundle)
    print(json.dumps(report))

def package_dependencies(bundle, files):
    # Local shlibs entries describe our private media libraries. dpkg-shlibdeps
    # still resolves every external system library and uses its real symbols.
    with tempfile.TemporaryDirectory(prefix='rillight-shlibs-') as work:
        debian = Path(work) / 'debian'
        debian.mkdir()
        (debian / 'control').write_text(
            'Source: rillight\nSection: video\nPriority: optional\nMaintainer: Rillight\n'
            '\nPackage: rillight\nArchitecture: any\nDescription: Rillight desktop client\n')
        local = []
        for meta in files.values():
            match = re.fullmatch(r'(.+)\.so\.(.+)', meta['soname'] or '')
            if match:
                local.append(f'{match[1]} {match[2]} rillight')
            elif meta['soname'] == 'librillight_core.so':
                local.append('librillight_core 0 rillight')
        (debian / 'shlibs.local').write_text('\n'.join(sorted(set(local))) + '\n')
        output = run(['dpkg-shlibdeps', '-O', '-xrillight', '-l' + str(Path(bundle) / 'lib'),
                      *['-e' + str(path) for path in files]], cwd=work)
    dependencies = next((line.split('=', 1)[1] for line in output.splitlines()
                         if line.startswith('shlibs:Depends=')), None)
    if not dependencies:
        raise ValueError('dpkg-shlibdeps produced no system dependencies')
    if re.search(r'(^|,)\s*(mpv|libmpv\d)', dependencies):
        raise ValueError('Deb must not depend on retired libmpv')
    return dependencies + ', ca-certificates, libc-bin, zenity, libgl1-mesa-dri, libglx-mesa0, libegl-mesa0'

def package_deb(bundle, version, output):
    if not re.fullmatch(r'[0-9][A-Za-z0-9.+:~\-]*', version):
        raise ValueError('Invalid Debian version')
    bundle, output = Path(bundle).resolve(), Path(output).resolve()
    files = verify_bundle(bundle)
    dependencies = package_dependencies(bundle, files)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='rillight-deb-') as staging:
        staging = Path(staging)
        install = staging / 'opt/rillight'
        shutil.copytree(bundle, install, symlinks=True)
        desktop = staging / 'usr/share/applications/rillight.desktop'
        desktop.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / 'linux/packaging/rillight.desktop', desktop)
        icon = staging / 'usr/share/icons/hicolor/256x256/apps/rillight.png'
        icon.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / 'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png', icon)
        command = staging / 'usr/bin/rillight'
        command.parent.mkdir(parents=True)
        command.write_text('#!/bin/sh\nexec /opt/rillight/rillight-launch "$@"\n', encoding='utf-8')
        command.chmod(0o755)
        verify_entrypoints(install, desktop)
        control = staging / 'DEBIAN'
        control.mkdir()
        size = sum(path.stat().st_size for path in install.rglob('*') if path.is_file()) // 1024
        (control / 'control').write_text(
            f'Package: rillight\nVersion: {version}\nSection: video\nPriority: optional\n'
            f'Architecture: amd64\nDepends: {dependencies}\nMaintainer: com.sakullla\n'
            f'Installed-Size: {size}\nDescription: Rillight desktop Emby client\n')
        run(['dpkg-deb', '--build', '--root-owner-group', staging, output])
    print(output)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    bundle = sub.add_parser('bundle')
    bundle.add_argument('prefix')
    bundle.add_argument('bundle')
    verify = sub.add_parser('verify')
    verify.add_argument('bundle')
    verify.add_argument('--static', action='store_true', help='ELF/entrypoint checks only; no Linux runtime claim')
    verify.add_argument('--desktop')
    package = sub.add_parser('deb')
    package.add_argument('bundle')
    package.add_argument('version')
    package.add_argument('output')
    args = parser.parse_args()
    if args.command == 'bundle':
        prepare_bundle(args.prefix, args.bundle)
    elif args.command == 'verify':
        files = verify_bundle(args.bundle, runtime=not args.static, desktop=args.desktop)
        print(f'Checked {len(files)} ELF files; runtime={not args.static}')
    else:
        package_deb(args.bundle, args.version, args.output)

if __name__ == '__main__':
    main()
