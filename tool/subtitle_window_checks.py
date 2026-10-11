"""Observe multi-line and dual subtitles in a real Windows player window.

Runs the production main with synthetic loopback Emby media under an isolated
validation directory, drives both subtitle slots through the real controller,
captures actual window pixels for each phase, and fails when any evidence
(sampled slots, per-phase screenshots, pixel differences) is missing.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from PIL import ImageChops, ImageGrab, ImageStat

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'packages/rillight_player/native'
PHASES = ['subtitles-off', 'primary-multiline', 'dual-subtitle', 'subtitles-off-again']


def flutter_tool():
    located = shutil.which('flutter') or shutil.which('flutter.bat')
    if located is None:
        raise RuntimeError('flutter must be on PATH for the release build')
    return located


def find_window(pid):
    user32 = ctypes.windll.user32
    matches = []
    callback_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)

    def visit(hwnd, _):
        owner = ctypes.c_ulong()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd):
            matches.append(hwnd)
        return True

    callback = callback_type(visit)
    user32.EnumWindows(callback, 0)
    if len(matches) != 1:
        raise RuntimeError(f'Expected one visible player window for PID {pid}')
    return user32, matches[0]


def capture_window(pid):
    """Grab the lower half of the real player window; return the PIL image."""
    user32, hwnd = find_window(pid)
    user32.SetWindowPos(hwnd, -1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040)
    time.sleep(0.35)
    rect = (ctypes.c_long * 4)()
    if not user32.GetWindowRect(hwnd, ctypes.byref(rect)):
        raise RuntimeError('Player window bounds unavailable')
    left, top, right, bottom = rect
    width, height = right - left, bottom - top
    if width < 320 or height < 180:
        raise RuntimeError('Player window too small for subtitle sampling')
    grab = ImageGrab.grab().convert('RGB')
    return grab.crop((left, top + height // 2, right, bottom)), (left, top, right, bottom)


def band(image, top_fraction, bottom_fraction):
    width, height = image.size
    return image.crop((0, int(height * top_fraction), width, int(height * bottom_fraction)))


def diff_metrics(before, after):
    difference = ImageChops.difference(before, after)
    stats = ImageStat.Stat(difference)
    grayscale = difference.convert('L')
    histogram = grayscale.histogram()
    return {
        'meanRgbDifference': sum(stats.mean) / len(stats.mean),
        'changedPixels': sum(histogram[20:]),
        'peakDifference': grayscale.getextrema()[1],
    }


def wait_for(predicate, timeout, message):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, default=ROOT / 'build/ffmpeg-core-windows-hw-sdk')
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--build', type=Path, default=ROOT / 'build/subtitle-window-checks')
    args = parser.parse_args()
    if sys.platform != 'win32':
        raise RuntimeError('The real-window subtitle check runs on Windows only')

    sdk = args.sdk.resolve()
    if not sdk.exists():
        raise RuntimeError(
            f'Pinned Windows FFmpeg core SDK missing: {sdk}. '
            'Provide --sdk or build/ffmpeg-core-windows-hw-sdk.')
    sys.path.insert(0, str(NATIVE))
    from verify_core_dependencies import verify
    errors = verify(sdk, 'windows-x64', require_subtitles=True)
    if errors:
        raise RuntimeError('\n'.join(errors))

    build_root = args.build.resolve()
    output = build_root / time.strftime('%Y%m%d-%H%M%S')
    output.mkdir(parents=True, exist_ok=True)
    media = build_root / 'media'
    ffmpeg = None
    for candidate in [
        ROOT / 'build/player-validation/tools/ffmpeg-9.0.2-essentials_build/bin/ffmpeg.exe',
        ROOT / 'build/android-validation/tools/ffmpeg-9.0.2-essentials_build/bin/ffmpeg.exe',
    ]:
        if candidate.exists():
            ffmpeg = candidate
            break
    if ffmpeg is None:
        located = subprocess.run(['where', 'ffmpeg'], capture_output=True, text=True)
        if located.returncode == 0 and located.stdout.strip():
            ffmpeg = Path(located.stdout.strip().splitlines()[0])
    if ffmpeg is None or not ffmpeg.exists():
        raise RuntimeError('ffmpeg is required to generate synthetic subtitle-window fixtures')

    subprocess.run([sys.executable, str(ROOT / 'tool/player_fixtures.py'),
                    '--media', str(media), '--ffmpeg', str(ffmpeg)], check=True)

    env = os.environ.copy()
    env['RILLIGHT_CORE_PREFIX_WINDOWS_X64'] = str(sdk)
    try:
        if not args.skip_build:
            # CMake keeps the first configured core prefix in its cache; an
            # older cached SDK would keep shipping a stale ABI. Drop the cache
            # when it disagrees with the requested SDK so configure re-runs.
            cache_file = ROOT / 'build/windows/x64/CMakeCache.txt'
            if cache_file.exists():
                cached = [line for line in cache_file.read_text(encoding='utf-8', errors='replace').splitlines()
                          if line.startswith('RILLIGHT_CORE_PREFIX_WINDOWS_X64:PATH=')]
                if cached and not cached[0].endswith(str(sdk)):
                    cache_file.unlink()
                    print(f'removed stale CMake cache prefix: {cached[0].split("=", 1)[1]}')
            # Incremental bundles keep a previously copied core DLL even after
            # the pinned SDK changes. Remove the outputs so the bundle step
            # must refresh them from the verified SDK.
            release = ROOT / 'build/windows/x64/runner/Release'
            for stale in release.glob('librillight_core.dll'):
                stale.unlink()
            subprocess.run([flutter_tool(), 'build', 'windows', '--release',
                            '--target', 'tool/subtitle_window_smoke.dart'],
                           cwd=ROOT, env=env, check=True)

        server = subprocess.Popen(
            [sys.executable, str(ROOT / 'tool/player_fixtures.py'),
             '--media', str(media), '--output', str(output)],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            server_json = output / 'server.json'
            wait_for(lambda: server_json.exists(), 15, 'Fixture server failed to start')
            app_env = os.environ.copy()
            app_env['RILLIGHT_VALIDATION_DIRECTORY'] = str(output)
            app_env['RILLIGHT_CORE_PREFIX_WINDOWS_X64'] = str(sdk)
            app = subprocess.Popen(
                [str(ROOT / 'build/windows/x64/runner/Release/rillight.exe')],
                cwd=ROOT, env=app_env,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print(f'Subtitle window evidence: {output}')

            player_log = output / 'player.jsonl'
            wait_for(lambda: player_log.exists(), 60,
                     'Player process did not start; see main.jsonl')
            pid = None
            for _ in range(100):
                rows = [json.loads(line) for line in player_log.read_text(encoding='utf-8').splitlines() if line.strip()]
                produced = [row for row in rows if row.get('event') == 'production-main' and row.get('value', {}).get('player')]
                if produced:
                    pid = produced[0]['value']['pid']
                    break
                time.sleep(0.2)
            if pid is None:
                raise RuntimeError('Player PID evidence missing from player.jsonl')

            captures = {}
            expected_ack = set()
            deadline = time.monotonic() + 420
            while len(expected_ack) < len(PHASES):
                if time.monotonic() > deadline:
                    raise RuntimeError('Timed out waiting for subtitle window phases')
                if app.poll() is not None:
                    raise RuntimeError('Player app exited before all phases completed')
                for phase in PHASES:
                    if phase in expected_ack:
                        continue
                    if (output / f'phase-{phase}.ready').exists():
                        image, bounds = capture_window(pid)
                        captures[phase] = image
                        image.save(output / f'subtitle-window-{phase}.png')
                        (output / f'phase-{phase}.ack').write_text('1')
                        expected_ack.add(phase)
                        print(f'captured {phase} (window {bounds})')
                time.sleep(0.2)
            wait_for(lambda: app.poll() is not None, 300,
                     'Player app did not exit after phases')

            result = json.loads((output / 'result.json').read_text(encoding='utf-8'))
            if result.get('passed') is not True:
                raise RuntimeError(f'Subtitle window smoke failed: {result.get("error")}')

            primary = diff_metrics(captures['subtitles-off'], captures['primary-multiline'])
            secondary = diff_metrics(band(captures['primary-multiline'], 0, 0.6),
                                     band(captures['dual-subtitle'], 0, 0.6))
            removed = diff_metrics(captures['dual-subtitle'], captures['subtitles-off-again'])
            evidence = {
                'pid': pid,
                'phases': PHASES,
                'primarySubtitleBand': primary,
                'secondarySubtitleBand': secondary,
                'subtitlesRemovedAgain': removed,
            }
            (output / 'subtitle-window-evidence.json').write_text(
                json.dumps(evidence, indent=2), encoding='utf-8')
            if primary['changedPixels'] < 200 or primary['peakDifference'] < 40:
                raise RuntimeError('Primary multi-line subtitle produced no visible window pixels')
            if secondary['changedPixels'] < 100 or secondary['peakDifference'] < 30:
                raise RuntimeError('Secondary subtitle produced no additional window pixels')
            if removed['changedPixels'] < 100:
                raise RuntimeError('Turning both slots off did not change the window')
        finally:
            if server.poll() is None:
                server.kill()
    finally:
        if not args.skip_build:
            # Leave the distribution artifact on the ordinary lib/main.dart entrypoint.
            subprocess.run([flutter_tool(), 'build', 'windows', '--release'],
                           cwd=ROOT, env=env, check=True)
    print('Real Windows window multi-line and dual subtitle evidence collected.')


if __name__ == '__main__':
    main()
