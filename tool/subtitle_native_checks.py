"""Verify the pinned SDK, build candidate subtitle tests, and require CTest evidence."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'packages/rillight_player/native'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', required=True, type=Path)
    parser.add_argument('--build', type=Path, default=ROOT / 'build/subtitle-native-checks')
    args = parser.parse_args()
    sdk, build = args.sdk.resolve(), args.build.resolve()
    if sys.platform == "win32":
        build = build / "ucrt64"
    sys.path.insert(0, str(NATIVE))
    from verify_core_dependencies import verify
    platform = 'windows-x64' if sys.platform == 'win32' else ('macos-universal' if sys.platform == 'darwin' else 'linux-x64')
    errors = verify(sdk, platform, require_subtitles=True)
    if errors:
        raise RuntimeError('\n'.join(errors))
    env = os.environ.copy()
    candidates = [sdk / 'bin', Path('C:/msys64/ucrt64/bin')] if sys.platform == 'win32' else [sdk / 'bin']
    env['PATH'] = os.pathsep.join(map(str, candidates)) + os.pathsep + env.get('PATH', '')
    env['LD_LIBRARY_PATH'] = str(sdk / 'lib') + os.pathsep + env.get('LD_LIBRARY_PATH', '')
    env['DYLD_LIBRARY_PATH'] = str(sdk / 'lib')
    cmake = shutil.which('cmake', path=env['PATH'])
    ctest = shutil.which('ctest', path=env['PATH'])
    if not cmake or not ctest:
        raise RuntimeError('CMake and CTest are required')
    build.mkdir(parents=True, exist_ok=True)
    with (build / 'checks.log').open('w', encoding='utf-8') as log:
        def run(command):
            print(subprocess.list2cmdline(list(map(str, command))), flush=True)
            completed = subprocess.run(list(map(str, command)), env=env, cwd=ROOT,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace')
            print(completed.stdout, end='')
            log.write(subprocess.list2cmdline(list(map(str, command))) + '\n' + completed.stdout)
            log.flush()
            completed.check_returncode()
            return completed.stdout
        configure = [cmake, '-S', NATIVE, '-B', build, '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Debug', f'-DRILLIGHT_CORE_PREFIX={sdk.as_posix()}']
        if sys.platform == 'win32':
            configure += ['-DCMAKE_C_COMPILER=C:/msys64/ucrt64/bin/gcc.exe', '-DCMAKE_CXX_COMPILER=C:/msys64/ucrt64/bin/g++.exe']
        run(configure)
        run([cmake, '--build', build, '--target', 'rillight_core_ass_test', 'rillight_bitmap_subtitle_test', '--parallel', '4'])
        pattern = 'rillight_core_(ass_composition|subtitle_presentation|mov_text)|rillight_bitmap_subtitle'
        listing = run([ctest, '--test-dir', build, '-N', '-R', pattern])
        if 'Total Tests: 4' not in listing:
            raise RuntimeError('All four subtitle tests must be discovered')
        run([ctest, '--test-dir', build, '--output-on-failure', '--no-tests=error', '-R', pattern])

if __name__ == '__main__':
    main()
