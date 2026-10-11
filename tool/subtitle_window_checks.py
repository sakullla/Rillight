"""Observe multi-line and dual subtitles in a real Windows player window.

Runs the production main with synthetic loopback Emby media under an isolated
validation directory, drives both subtitle slots through the real controller,
captures actual window pixels for each phase, and fails when any evidence
(sampled slots, per-phase screenshots, pixel differences) is missing.
"""
import argparse
import ctypes
import ctypes.wintypes as wintypes
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


class WindowThumbnail:
    """Render a window's real DWM-composed pixels into a plain GDI window.

    The Flutter player window presents through a flip-model swap chain that
    GDI screen capture (ImageGrab, BitBlt) cannot see; capturing it directly
    photographs whatever sits behind it. A DWM thumbnail composes the actual
    window content into an ordinary window that GDI captures reliably.
    """

    def __init__(self, width, height):
        self.user32 = ctypes.windll.user32
        self.dwmapi = ctypes.windll.dwmapi
        self.width, self.height = width, height
        self.user32.DefWindowProcW.argtypes = [
            ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t, ctypes.c_ssize_t]
        self.user32.DefWindowProcW.restype = ctypes.c_ssize_t
        wndproc = ctypes.WINFUNCTYPE(ctypes.c_ssize_t, ctypes.c_void_p,
                                     ctypes.c_uint, ctypes.c_size_t,
                                     ctypes.c_ssize_t)
        self._wndproc = wndproc(
            lambda hwnd, msg, wp, lp: self.user32.DefWindowProcW(hwnd, msg, wp, lp))

        class WNDCLASSW(ctypes.Structure):
            _fields_ = [('style', ctypes.c_uint), ('lpfnWndProc', wndproc),
                        ('cbClsExtra', ctypes.c_int), ('cbWndExtra', ctypes.c_int),
                        ('hInstance', ctypes.c_void_p), ('hIcon', ctypes.c_void_p),
                        ('hCursor', ctypes.c_void_p),
                        ('hbrBackground', ctypes.c_void_p),
                        ('lpszMenuName', wintypes.LPCWSTR),
                        ('lpszClassName', wintypes.LPCWSTR)]

        wc = WNDCLASSW()
        wc.lpfnWndProc = self._wndproc
        wc.hInstance = ctypes.c_void_p(
            ctypes.windll.kernel32.GetModuleHandleW(None))
        wc.lpszClassName = 'RillightWindowThumbnail'
        if not self.user32.RegisterClassW(ctypes.byref(wc)):
            raise RuntimeError('thumbnail window registration failed')
        self.probe = self.user32.CreateWindowExW(
            0, 'RillightWindowThumbnail', 'rillight-window-check-thumbnail',
            0x00CF0000, 100, 100, width, height, None, None,
            int(wc.hInstance) & 0xffffffff, None)
        if not self.probe:
            raise RuntimeError('thumbnail window creation failed')
        self.user32.ShowWindow(self.probe, 5)
        self.user32.UpdateWindow(self.probe)
        time.sleep(0.2)
        self.thumbnail = None

    def capture(self, hwnd):
        rect = (ctypes.c_long * 4)()
        if not self.user32.GetWindowRect(hwnd, ctypes.byref(rect)):
            raise RuntimeError('Player window bounds unavailable')
        if self.thumbnail is None:
            self.thumbnail = ctypes.c_void_p()
            if self.dwmapi.DwmRegisterThumbnail(ctypes.c_void_p(self.probe),
                                                ctypes.c_void_p(hwnd),
                                                ctypes.byref(self.thumbnail)) != 0:
                self.thumbnail = None
                raise RuntimeError('DWM thumbnail registration failed')

        class THUMBNAIL_PROPERTIES(ctypes.Structure):
            _fields_ = [('dwFlags', ctypes.c_uint),
                        ('rcDestination', wintypes.RECT),
                        ('rcSource', wintypes.RECT),
                        ('opacity', ctypes.c_byte), ('fVisible', ctypes.c_byte),
                        ('fSourceClientAreaOnly', ctypes.c_byte),
                        ('fAlphaChannel', ctypes.c_byte)]

        properties = THUMBNAIL_PROPERTIES()
        properties.dwFlags = 0x1f
        properties.rcDestination = wintypes.RECT(0, 0, self.width, self.height)
        properties.rcSource = wintypes.RECT(0, 0, rect[2] - rect[0], rect[3] - rect[1])
        properties.opacity = 255
        properties.fVisible = 1
        properties.fSourceClientAreaOnly = 1
        self.dwmapi.DwmUpdateThumbnailProperties(
            self.thumbnail, ctypes.byref(properties))
        self.user32.SetWindowPos(self.probe, -1, 0, 0, 0, 0,
                                 0x0001 | 0x0002 | 0x0040)
        time.sleep(0.35)
        grab = ImageGrab.grab().convert('RGB')
        return grab.crop((100, 100, 100 + self.width, 100 + self.height)), \
            (rect[0], rect[1], rect[2], rect[3])

    def close(self):
        if self.thumbnail:
            self.dwmapi.DwmUnregisterThumbnail(self.thumbnail)
            self.thumbnail = None
        if self.probe:
            self.user32.DestroyWindow(self.probe)
            self.probe = None


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


def capture_window(pid, thumbnail):
    """Grab the full real player window; return the PIL image."""
    _, hwnd = find_window(pid)
    image, bounds = thumbnail.capture(hwnd)
    if bounds[2] - bounds[0] < 320 or bounds[3] - bounds[1] < 180:
        raise RuntimeError('Player window too small for subtitle sampling')
    return image, bounds


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
    # Window rectangles and screenshots must share one coordinate space.
    # Without DPI awareness GetWindowRect reports logical pixels while
    # ImageGrab returns physical pixels; on a scaled desktop the crop then
    # misses the lower part of the player window and the subtitle band.
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except Exception:
        ctypes.windll.user32.SetProcessDPIAware()

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
            thumbnail = WindowThumbnail(960, 540)
            try:
                while len(expected_ack) < len(PHASES):
                    if time.monotonic() > deadline:
                        raise RuntimeError('Timed out waiting for subtitle window phases')
                    if app.poll() is not None:
                        raise RuntimeError('Player app exited before all phases completed')
                    for phase in PHASES:
                        if phase in expected_ack:
                            continue
                        if (output / f'phase-{phase}.ready').exists():
                            image, bounds = capture_window(pid, thumbnail)
                            captures[phase] = image
                            image.save(output / f'subtitle-window-{phase}.png')
                            (output / f'phase-{phase}.ack').write_text('1')
                            expected_ack.add(phase)
                            print(f'captured {phase} (window {bounds})')
                    time.sleep(0.2)
            finally:
                thumbnail.close()
            wait_for(lambda: app.poll() is not None, 300,
                     'Player app did not exit after phases')

            result = json.loads((output / 'result.json').read_text(encoding='utf-8'))
            if result.get('passed') is not True:
                raise RuntimeError(f'Subtitle window smoke failed: {result.get("error")}')

            # The primary SRT renders near the bottom of the window; the
            # secondary ASS track is top-aligned. Compare disjoint bands so
            # each slot's pixels are measured where that slot renders.
            primary = diff_metrics(band(captures['subtitles-off'], 0.5, 1),
                                   band(captures['primary-multiline'], 0.5, 1))
            secondary = diff_metrics(band(captures['primary-multiline'], 0, 0.45),
                                     band(captures['dual-subtitle'], 0, 0.45))
            removed = diff_metrics(captures['dual-subtitle'],
                                   captures['subtitles-off-again'])
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
