"""Build current sources and validate Linux in a prepared Docker container.

Prerequisites: /cache/flutter (3.47.4), /cache/pub, /cache/native (pinned
media build), Linux build tools and the playback_smoke.sh dependencies.
The repository must be mounted read-only at /source, including the synthetic
build/player-validation/media fixtures. No existing build is accepted as proof.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def inside(output):
    output.mkdir(parents=True, exist_ok=False)
    env = {**os.environ, 'PUB_CACHE': '/cache/pub',
           'PATH': '/cache/flutter/bin:' + os.environ['PATH'],
           'RILLIGHT_MPV_PREFIX': '/cache/native',
           'PKG_CONFIG_PATH': '/cache/native/lib/pkgconfig',
           'LD_LIBRARY_PATH': '/cache/native/lib'}
    bundle = ROOT / 'build/linux/x64/release/bundle'

    def run(name, args, environment=env):
        print(name, flush=True)
        with (output / (name + '.log')).open('w') as log:
            result = subprocess.run(args, cwd=ROOT, env=environment,
                                    stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            print((output / (name + '.log')).read_text()[-12000:])
            raise RuntimeError(f'{name} failed ({result.returncode})')

    passed = False
    try:
        run('sdk', ['flutter', '--version', '--machine'])
        sdk = json.loads((output / 'sdk.log').read_text())
        if sdk['frameworkVersion'] != '3.47.4':
            raise RuntimeError('Linux validation requires Flutter 3.47.4')
        run('compiler', ['clang', '--version'])
        run('cmake', ['cmake', '--version'])
        run('dependencies', ['flutter', 'pub', 'get'])
        run('production-build', ['flutter', 'build', 'linux', '--release'])
        clean = {k: v for k, v in env.items()
                 if k not in ('LD_LIBRARY_PATH', 'LD_PRELOAD', 'LD_AUDIT')}
        run('production-elf', ['python3', 'tool/linux_release_checks.py',
                              'verify', str(bundle)], clean)
        (output / 'native-versions.json').write_bytes(
            (bundle / 'data/rillight_player/loaded-versions.json').read_bytes())
        native = {**clean, 'RILLIGHT_TEST_MPV': str(bundle / 'lib/libmpv.so.2'),
                  'RILLIGHT_TEST_MEDIA':
                  '/source/build/player-validation/media/baseline.mp4'}
        run('native-package', ['flutter', 'test', 'packages/rillight_player/test'], native)
        run('smoke-build', ['flutter', 'build', 'linux', '--release',
                            '--target', 'tool/player_smoke.dart'])
        run('smoke-elf', ['python3', 'tool/linux_release_checks.py',
                         'verify', str(bundle)], clean)
        run('window', ['xvfb-run', '-a', '-s', '-screen 0 1440x1000x24',
                       'dbus-run-session', '--', 'bash',
                       'linux/packaging/playback_smoke.sh', str(bundle),
                       '/source/build/player-validation/media',
                       str(output / 'window')], clean)
        passed = True
    finally:
        (output / 'validation.json').write_text(json.dumps({
            'passed': passed, 'environment': 'Docker Ubuntu / Xvfb / software Mesa',
            'osRelease': Path('/etc/os-release').read_text(),
            'hardwareValidated': False,
        }, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container')
    parser.add_argument('--inside', type=Path)
    args = parser.parse_args()
    if args.inside:
        inside(args.inside)
        return
    if not args.container:
        parser.error('--container is required')
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    output = ROOT / 'build/player-validation' / ('linux-current-' + stamp)
    output.mkdir(parents=True, exist_ok=False)
    docker = ['docker', 'exec', args.container]
    work = subprocess.check_output(docker + ['mktemp', '-d', '/work/rillight-validation-XXXXXX'],
                                   text=True).strip()
    with tempfile.TemporaryDirectory(prefix='rillight-linux-source-') as temporary:
        archive = Path(temporary) / 'source.tar'
        files = subprocess.check_output(['git', 'ls-files', '-z', '--cached',
                                         '--others', '--exclude-standard'], cwd=ROOT)
        with tarfile.open(archive, 'w') as tar:
            for name in sorted(set(files.decode().split('\0')) - {''}):
                path = ROOT / name
                if path.is_file() and not name.startswith('docs/'):
                    tar.add(path, arcname=name, recursive=False)
        (output / 'source.json').write_text(json.dumps({
            'gitHead': subprocess.check_output(['git', 'rev-parse', 'HEAD'],
                                               cwd=ROOT, text=True).strip(),
            'archiveSha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
            'container': args.container, 'sourceDirectory': work,
            'includesUncommittedChanges': True,
        }, indent=2) + '\n')
        subprocess.run(['docker', 'cp', str(archive), f'{args.container}:{work}/source.tar'], check=True)
    subprocess.run(docker + ['tar', '-xf', work + '/source.tar', '-C', work], check=True)
    try:
        subprocess.run(docker + ['python3', work + '/tool/linux_playback_validation.py',
                                 '--inside', work + '/evidence'], check=True)
    finally:
        subprocess.run(['docker', 'cp', f'{args.container}:{work}/evidence/.', str(output)], check=True)
        print(f'Evidence: {output}\nContainer sources: {work}', flush=True)


if __name__ == '__main__':
    main()
