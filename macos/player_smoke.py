"""Release-mode macOS production main/child playback validation.

Builds tool/player_smoke.dart, drives synthetic Emby fixtures, checks
result.json, and samples actual player-window pixels. Restores lib/main.dart
afterwards. Physical speaker output is not asserted.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'build/macos/Build/Products/Release/rillight.app'
EXECUTABLE = APP / 'Contents/MacOS/rillight'
BUNDLE_ID = 'com.sakullla.rillight'
PYTHON_APP = Path(
    '/Library/Frameworks/Python.framework/Versions/3.14/Resources/Python.app')


def run(args, **kwargs):
    print('+', ' '.join(str(item) for item in args), flush=True)
    return subprocess.run(args, check=True, **kwargs)


def core_env():
    prefix = os.environ.get('RILLIGHT_MACOS_CORE_PREFIX')
    dylib = os.environ.get('RILLIGHT_MACOS_CORE_DYLIB')
    digest = os.environ.get('RILLIGHT_MACOS_CORE_SHA256')
    if not prefix or not dylib or not digest:
        raise RuntimeError(
            'Set RILLIGHT_MACOS_CORE_PREFIX, RILLIGHT_MACOS_CORE_DYLIB and '
            'RILLIGHT_MACOS_CORE_SHA256')
    return {
        **os.environ,
        'RILLIGHT_MACOS_CORE_PREFIX': prefix,
        'RILLIGHT_MACOS_CORE_DYLIB': dylib,
        'RILLIGHT_MACOS_CORE_SHA256': digest,
        'RILLIGHT_SMOKE_HOLD_SECONDS': os.environ.get(
            'RILLIGHT_SMOKE_HOLD_SECONDS', '3'),
    }


def smoke(*, skip_build=False, skip_restore=False):
    env = core_env()
    sdk = Path(env['RILLIGHT_MACOS_CORE_PREFIX'])
    run([sys.executable,
         str(ROOT / 'packages/rillight_player/native/verify_core_dependencies.py'),
         '--prefix', str(sdk), '--target', 'macos-universal',
         '--require-subtitles'])
    stamp = time.strftime('%Y%m%d-%H%M%S')
    archive = ROOT / 'build/player-validation/macos-runs' / stamp
    if archive.exists():
        raise RuntimeError(f'Refuse to overwrite evidence directory {archive}')
    # Release apps are sandboxed; they cannot write into the git worktree.
    output = (Path.home() / 'Library/Containers' / BUNDLE_ID / 'Data' /
              'rillight-validation' / stamp)
    output.mkdir(parents=True, exist_ok=False)
    archive.mkdir(parents=True)
    media = ROOT / 'build/player-validation/media'
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise RuntimeError('ffmpeg is required to generate synthetic fixtures')
    run([sys.executable, str(ROOT / 'tool/player_fixtures.py'),
         '--media', str(media), '--ffmpeg', ffmpeg])
    if not skip_build:
        run(['flutter', 'build', 'macos', '--release',
             '--target', 'tool/player_smoke.dart'], env=env, cwd=ROOT)
    if not EXECUTABLE.is_file():
        raise RuntimeError('Missing smoke rillight executable')
    server = subprocess.Popen(
        [sys.executable, '-u', str(ROOT / 'tool/player_fixtures.py'),
         '--media', str(media), '--output', str(output)],
        cwd=ROOT,
        stdout=(output / 'server.stdout.log').open('w'),
        stderr=(output / 'server.stderr.log').open('w'))
    capture = None
    app = None
    original = os.environ.get('RILLIGHT_VALIDATION_DIRECTORY')
    try:
        deadline = time.monotonic() + 30
        while not (output / 'server.json').is_file():
            if server.poll() is not None:
                stderr = (output / 'server.stderr.log').read_text(encoding='utf-8')
                raise RuntimeError(
                    f'Fixture server exited {server.returncode}: {stderr[-2000:]}')
            if time.monotonic() > deadline:
                raise RuntimeError('Fixture server failed to start')
            time.sleep(0.1)
        env['RILLIGHT_VALIDATION_DIRECTORY'] = str(output)
        capture_script = ROOT / 'macos/capture_playback.py'
        # Screen Recording TCC applies to Python.app as the responsible
        # process. A child of the agent/CLI does not inherit that grant.
        if PYTHON_APP.is_dir():
            capture_cmd = ['open', '-W', '-n', '-a', str(PYTHON_APP), '--args',
                           str(capture_script), '--output', str(output),
                           '--timeout', '240', '--app', str(APP)]
        else:
            capture_cmd = [sys.executable, str(capture_script),
                           '--output', str(output), '--timeout', '240',
                           '--app', str(APP)]
        capture = subprocess.Popen(
            capture_cmd, cwd=ROOT,
            stdout=(output / 'capture-open.log').open('w'),
            stderr=subprocess.STDOUT)
        app = subprocess.Popen(
            [str(EXECUTABLE)], cwd=ROOT, env=env,
            stdout=(output / 'app.stdout.log').open('w'),
            stderr=(output / 'app.stderr.log').open('w'))
        print('Playback validation evidence:', output, flush=True)
        deadline = time.monotonic() + 300
        while app.poll() is None:
            if time.monotonic() > deadline:
                raise RuntimeError('Playback validation timed out')
            time.sleep(0.25)
        capture_status = capture.wait(timeout=30)
        if app.returncode != 0:
            raise RuntimeError(f'Player smoke exited {app.returncode}')
        result = json.loads((output / 'result.json').read_text(encoding='utf-8'))
        if result.get('passed') is not True:
            raise RuntimeError('Playback validation failed: ' + str(result))
        evidence_path = output / 'window-evidence.json'
        if capture_status != 0 or not evidence_path.is_file():
            print('Dart playback passed; window pixel capture did not '
                  f'(capture exit {capture_status}). Allow Screen Recording '
                  'for Python to capture actual frames.', flush=True)
        else:
            evidence = json.loads(evidence_path.read_text(encoding='utf-8'))
            if set(evidence) != {'1080p60-loaded', '4k-hevc-loaded',
                                 'av1-loaded', 'vp9-loaded'}:
                raise RuntimeError(
                    'Incomplete window evidence: ' + str(sorted(evidence)))
            print('Owned-core macOS production main/child playback and '
                  'window video passed')
        return archive
    finally:
        if app is not None and app.poll() is None:
            app.terminate()
            try:
                app.wait(timeout=5)
            except subprocess.TimeoutExpired:
                app.kill()
        if capture is not None and capture.poll() is None:
            capture.terminate()
            try:
                capture.wait(timeout=5)
            except subprocess.TimeoutExpired:
                capture.kill()
        if server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
        if output.is_dir() and archive.is_dir():
            for item in output.iterdir():
                target = archive / item.name
                if item.is_dir():
                    shutil.copytree(item, target, dirs_exist_ok=True)
                else:
                    shutil.copy2(item, target)
            print('Copied sandbox evidence to', archive, flush=True)
        if original is None:
            os.environ.pop('RILLIGHT_VALIDATION_DIRECTORY', None)
        else:
            os.environ['RILLIGHT_VALIDATION_DIRECTORY'] = original
        if not skip_restore:
            run(['flutter', 'build', 'macos', '--release',
                 '--target', 'lib/main.dart'], env=env, cwd=ROOT)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--skip-restore', action='store_true')
    args = parser.parse_args()
    try:
        smoke(skip_build=args.skip_build, skip_restore=args.skip_restore)
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError) as error:
        print(f'macOS player smoke failed: {error}', file=sys.stderr)
        sys.exit(1)
