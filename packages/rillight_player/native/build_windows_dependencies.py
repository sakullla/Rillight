"""Build the pinned Windows media SDK and candidate core using MSYS2 MinGW64."""

import argparse
import json
import os
from build_subtitle_unicode import meson_source
from pathlib import Path
import re
import shlex
import shutil
import subprocess

from build_core_dependencies import (
    fetch_source, install_enhancement_runtime, locked_ffmpeg_patches)
from verify_core_dependencies import ROOT, SPEC, digest, verify


def copy_runtime_dependencies(prefix: Path, mingw: Path) -> None:
    """Copy transitive MinGW DLL imports, leaving Windows DLLs to the OS."""
    pending = list((prefix / 'bin').glob('*.dll'))
    seen = set()
    system = Path(os.environ['SystemRoot']) / 'System32'
    while pending:
        library = pending.pop()
        if library.name.lower() in seen:
            continue
        seen.add(library.name.lower())
        output = subprocess.check_output(
            [str(mingw / 'bin/objdump.exe'), '-p', str(library)], text=True)
        for name in re.findall(r'DLL Name:\s*(\S+)', output):
            destination = prefix / 'bin' / name
            source = mingw / 'bin' / name
            if destination.is_file():
                pending.append(destination)
            elif source.is_file():
                shutil.copy2(source, destination)
                pending.append(destination)
            elif not (name.lower().startswith(('api-ms-win-', 'ext-ms-win-')) or
                      (system / name).is_file()):
                raise RuntimeError(f'Missing runtime dependency: {name} ({library.name})')


def record_libraries(prefix: Path, marker: dict) -> None:
    marker['libraries'] = {
        path.relative_to(prefix).as_posix(): digest(path)
        for path in sorted([*(prefix / 'bin').glob('*.dll'),
                            *(prefix / 'lib').glob('*.dll.a')])
    }
    (prefix / 'rillight-core-dependencies.json').write_text(
        json.dumps(marker, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--msys-root', type=Path, default=Path('C:/msys64'))
    parser.add_argument('--jobs', type=int, default=min(8, os.cpu_count() or 2))
    args = parser.parse_args()
    prefix, work, msys = (path.resolve() for path in
                          (args.prefix, args.work, args.msys_root))
    prefix.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    mingw = msys / 'mingw64'
    environment = {**os.environ, 'MSYSTEM': 'MINGW64', 'CHERE_INVOKING': '1'}

    def unix(path):
        return subprocess.check_output(
            [str(msys / 'usr/bin/cygpath.exe'), '-u', str(path)], text=True).strip()

    def shell(script, *, capture=False):
        command = [str(msys / 'usr/bin/bash.exe'), '-lc',
                   'set -euo pipefail\nexport PATH=/mingw64/bin:/usr/bin:$PATH\n' + script]
        if capture:
            return subprocess.check_output(command, env=environment, text=True).strip()
        subprocess.run(command, env=environment, check=True)

    prefix_unix = unix(prefix)
    if verify(prefix, 'windows-x64', require_subtitles=True):
        for name in ('dav1d', 'libass', 'ffmpeg'):
            spec = SPEC[name]
            source = work / name
            if name == 'ffmpeg' and (source / '.git').exists():
                for patch in locked_ffmpeg_patches().values():
                    if subprocess.run(['git', '-C', str(source), 'apply', '--reverse',
                                       '--check', str(patch)], capture_output=True).returncode == 0:
                        subprocess.run(['git', '-C', str(source), 'apply', '--reverse',
                                        str(patch)], check=True)
            fetch_source(source, spec['repository'], spec['commit'], spec['version'])
        for patch in locked_ffmpeg_patches().values():
            subprocess.run(['git', '-C', str(work / 'ffmpeg'), 'apply', str(patch)], check=True)

        unicode_spec = SPEC['libass']['unicode_line_breaks']
        unicode_source = work / 'libunibreak'
        fetch_source(unicode_source, unicode_spec['repository'], unicode_spec['commit'], unicode_spec['tag'])
        unicode_project = meson_source(unicode_source, work / 'libunibreak-project', unicode_spec['version'])
        for name, options in (
            ('libunibreak', []),
            ('dav1d', ['-Denable_tools=false', '-Denable_tests=false']),
            ('libass', ['-Dfontconfig=enabled', '-Drequire-system-font-provider=true', '-Dlibunibreak=enabled']),
        ):
            build = work / (name + '-build')
            setup = ['meson', 'setup', unix(build), unix(unicode_project if name == 'libunibreak' else work / name),
                     f'--prefix={prefix_unix}', '--libdir=lib', '--buildtype=release',
                     '-Ddefault_library=shared', *options]
            if (build / 'build.ninja').exists():
                setup.append('--reconfigure')
            shell(f'export PKG_CONFIG_PATH={shlex.quote(prefix_unix + "/lib/pkgconfig")}\n' +
                  shlex.join(setup) + '\n' +
                  f'meson compile -C {shlex.quote(unix(build))} -j{args.jobs}\n' +
                  f'meson install -C {shlex.quote(unix(build))}\n')

        build = work / 'ffmpeg-build'
        build.mkdir(exist_ok=True)
        configure = [f'--prefix={prefix_unix}', f'--libdir={prefix_unix}/lib',
                     '--target-os=mingw32', '--arch=x86_64', '--enable-shared',
                     '--disable-static', '--disable-programs', '--disable-doc',
                     '--enable-network', '--disable-autodetect', '--enable-avfilter',
                     '--enable-swresample', '--enable-swscale', '--enable-d3d11va',
                     '--enable-dxva2', '--enable-libdav1d',
                     '--enable-decoder=ac3', '--enable-decoder=eac3',
                     '--enable-decoder=truehd']
        shell(f'export PKG_CONFIG_PATH={shlex.quote(prefix_unix + "/lib/pkgconfig")}\n' +
              f'cd {shlex.quote(unix(build))}\n' +
              shlex.join([unix(work / 'ffmpeg/configure'), *configure]) + '\n' +
              f'make -j{args.jobs}\nmake install\n')
        copy_runtime_dependencies(prefix, mingw)
        marker = {'schema': 1, 'platform': 'windows-x64',
                  'ffmpeg_version': SPEC['ffmpeg']['version'],
                  'ffmpeg_tag': SPEC['ffmpeg']['version'],
                  'ffmpeg_commit': SPEC['ffmpeg']['commit'],
                  'ffmpeg_patches': SPEC['ffmpeg'].get('patches', {}),
                  'configure': configure}
        for name, pattern in (('dav1d', '*dav1d*.dll'), ('libass', '*ass-*.dll')):
            library, = (prefix / 'bin').glob(pattern)
            marker[name] = {'version': SPEC[name]['version'], 'commit': SPEC[name]['commit'],
                            'library': library.relative_to(prefix).as_posix(),
                            'sha256': digest(library)}
        marker['libass']['unicode_line_breaks'] = unicode_spec
        marker['libass']['build_dependencies'] = {
            name: shell(shlex.join(['pkg-config', '--modversion', name]), capture=True)
            for name in SPEC['libass']['required_build_dependencies']
        }
        record_libraries(prefix, marker)
    else:
        print(f'Using verified Windows SDK: {prefix}', flush=True)
        marker = json.loads((prefix / 'rillight-core-dependencies.json').read_text())

    # The dependency cache never substitutes for compiling the candidate core.
    core_build = work / 'core-build'
    shell(shlex.join(['cmake', '-S', unix(ROOT), '-B', unix(core_build), '-G', 'Ninja',
                      '-DCMAKE_BUILD_TYPE=Release',
                      '-DCMAKE_C_COMPILER=/mingw64/bin/cc.exe',
                      '-DCMAKE_CXX_COMPILER=/mingw64/bin/c++.exe',
                      f'-DRILLIGHT_CORE_PREFIX={prefix_unix}']) + '\n' +
          shlex.join(['cmake', '--build', unix(core_build), '--target', 'rillight_core',
                      '--parallel', str(args.jobs)]))
    shutil.copy2(core_build / 'librillight_core.dll', prefix / 'bin/librillight_core.dll')
    install_enhancement_runtime(core_build, prefix / 'bin')
    copy_runtime_dependencies(prefix, mingw)
    record_libraries(prefix, marker)
    errors = verify(prefix, 'windows-x64', require_subtitles=True)
    if errors:
        raise RuntimeError('\n'.join(errors))
    print(f'Built and verified Windows SDK and candidate core: {prefix}')


if __name__ == '__main__':
    main()
