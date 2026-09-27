"""Capture two real Windows player-window crops during synthetic playback."""

import argparse
import ctypes
import json
from pathlib import Path
import time

from PIL import ImageChops, ImageGrab, ImageStat


def player_window(pid):
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


def capture(pid, output, phase):
    user32, hwnd = player_window(pid)
    user32.ShowWindow(hwnd, 5)
    # Windows may deny foreground focus to this helper even while the player
    # is visible. Raise its Z-order for a screen grab without requiring focus.
    user32.SetWindowPos(hwnd, -1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.4)
    rect = (ctypes.c_long * 4)()
    if not user32.GetWindowRect(hwnd, ctypes.byref(rect)):
        raise RuntimeError('Player window bounds unavailable')
    left, top, right, bottom = rect
    width, height = right - left, bottom - top
    if width < 320 or height < 180:
        raise RuntimeError('Player window too small for a frame sample')
    crop = (left + width // 4, top + height // 4,
            left + 3 * width // 4, top + 3 * height // 4)
    first = ImageGrab.grab(bbox=crop).convert('RGB')
    first.save(output / f'cache-long-{phase}-frame-a.png')
    time.sleep(2)
    second = ImageGrab.grab(bbox=crop).convert('RGB')
    second.save(output / f'cache-long-{phase}-frame-b.png')
    difference = ImageChops.difference(first, second)
    channels = ImageStat.Stat(difference).mean
    changed_pixels = sum(difference.convert('L').histogram()[20:])
    peak_difference = difference.convert('L').getextrema()[1]
    evidence = {'pid': pid, 'phase': phase, 'windowBounds': [left, top, right, bottom],
                'crop': crop, 'meanChannelDifference': channels,
                'meanRgbDifference': sum(channels) / 3,
                'changedPixels': changed_pixels,
                'peakDifference': peak_difference}
    (output / f'cache-long-{phase}-window-motion.json').write_text(
        json.dumps(evidence, indent=2), encoding='utf-8')
    print(json.dumps(evidence))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--phase', choices=('early', 'middle', 'late'), required=True)
    args = parser.parse_args()
    capture(args.pid, args.output.resolve(), args.phase)
