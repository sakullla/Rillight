"""Assert real Cocoa player-window video, not just successful control messages.

Samples require color inside the child window's video region, excluding
controls and window chrome. This is not physical-speaker verification.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
from datetime import datetime

from PIL import Image

WANTED = ('1080p60-loaded', '4k-hevc-loaded', 'av1-loaded', 'vp9-loaded')


def records(root):
    path = root / 'player.jsonl'
    if not path.exists():
        return []
    result = []
    for line in path.read_text(encoding='utf-8').splitlines():
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return result


def player_pid(events):
    for event in events:
        if event.get('event') != 'production-main':
            continue
        value = event.get('value') or {}
        if value.get('player') is True and isinstance(value.get('pid'), int):
            return value['pid']
    return None


def list_rillight_windows():
    script = (
        'tell application "System Events"\n'
        'set report to ""\n'
        'repeat with p in (every process whose name is "rillight")\n'
        'try\n'
        'set uid to unix id of p\n'
        'repeat with w in windows of p\n'
        'set pos to position of w\n'
        'set sz to size of w\n'
        'set nm to ""\n'
        'try\n'
        'set nm to name of w as text\n'
        'end try\n'
        'set report to report & (uid as text) & "|" & nm & "|" & '
        '(item 1 of pos as text) & "," & (item 2 of pos as text) & "," & '
        '(item 1 of sz as text) & "," & (item 2 of sz as text) & linefeed\n'
        'end repeat\n'
        'end try\n'
        'end repeat\n'
        'return report\n'
        'end tell'
    )
    output = subprocess.check_output(
        ['osascript', '-e', script], text=True, stderr=subprocess.STDOUT)
    windows = []
    for line in output.splitlines():
        parts = line.split('|', 2)
        if len(parts) != 3:
            continue
        uid, name, rect = parts
        x, y, width, height = (int(float(piece)) for piece in rect.split(','))
        windows.append({
            'pid': int(uid), 'name': name, 'bounds': (x, y, width, height),
            'area': width * height,
        })
    return windows


def raise_pid(pid):
    script = (
        'tell application "System Events"\n'
        f'set procs to every process whose unix id is {int(pid)}\n'
        'if procs is {} then return\n'
        'set frontmost of item 1 of procs to true\n'
        'end tell'
    )
    subprocess.run(['osascript', '-e', script], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def window_bounds(pid):
    windows = list_rillight_windows()
    print('rillight windows:', windows, flush=True)
    matching = [item for item in windows if item['pid'] == int(pid)
                and item['bounds'][2] >= 400 and item['bounds'][3] >= 200]
    if matching:
        chosen = max(matching, key=lambda item: item['area'])
        raise_pid(chosen['pid'])
        time.sleep(0.2)
        return chosen['bounds']
    # The catalog host is also named rillight. Prefer a 1280x720-class window.
    playable = [item for item in windows
                if item['bounds'][2] >= 900 and item['bounds'][3] >= 500]
    if playable:
        chosen = min(playable,
                     key=lambda item: abs(item['bounds'][2] - 1280) +
                     abs(item['bounds'][3] - 720))
        raise_pid(chosen['pid'])
        time.sleep(0.2)
        return chosen['bounds']
    raise RuntimeError(f'No player window for pid {pid}: {windows}')


def activate_app(app):
    if app is None:
        return
    subprocess.run(['open', '-a', str(app)], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.3)


def capture_window(pid, destination, app=None):
    destination = Path(destination)
    activate_app(app)
    try:
        x, y, width, height = window_bounds(pid)
        command = ['screencapture', '-x', '-t', 'png',
                   '-R', f'{x},{y},{width},{height}', str(destination)]
        subprocess.check_call(command)
    except (RuntimeError, subprocess.CalledProcessError):
        subprocess.check_call(['screencapture', '-x', '-t', 'png', '-m',
                               str(destination)])
    if not destination.is_file() or destination.stat().st_size < 32:
        raise RuntimeError('screencapture produced no window image')
    return Image.open(destination).convert('RGB')


def colored_fraction(image):
    width, height = image.size
    video = image.crop((int(width * .15), int(height * .2),
                        int(width * .85), int(height * .75))).resize((160, 90))
    colors = list(video.getdata())
    fraction = sum(max(rgb) - min(rgb) > 50 and max(rgb) > 80
                   for rgb in colors) / len(colors)
    return fraction, hashlib.sha256(video.tobytes()).hexdigest()


def capture(root, timeout=210, app=None):
    root = Path(root).resolve()
    captured = {}
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        events = records(root)
        pid = player_pid(events)
        if pid is None:
            time.sleep(0.05)
            continue
        for event in events:
            kind = event.get('event')
            if kind not in WANTED or kind in captured:
                continue
            began = time.monotonic()
            loaded_at = datetime.fromisoformat(event['at']).timestamp()
            samples, streak, first_visible = [], 0, None
            while time.monotonic() - began < (8 if first_visible is None else 5):
                latest = next((row['event'] for row in reversed(records(root))
                               if row.get('event', '').endswith('-loaded')), kind)
                if latest != kind:
                    raise RuntimeError(
                        f'{kind}: source changed before stable video was verified ({latest})')
                image = capture_window(
                    pid, root / f'{kind}-{len(samples)}-window.png', app=app)
                fraction, video_hash = colored_fraction(image)
                elapsed = time.time() - loaded_at
                samples.append({'elapsedSeconds': elapsed,
                                'coloredFraction': fraction,
                                'videoHash': video_hash})
                if fraction >= 0.05:
                    if first_visible is None:
                        first_visible = elapsed
                    streak += 1
                else:
                    streak = 0
                captured[kind] = {
                    'pid': pid, 'size': list(image.size),
                    'firstVisibleSeconds': first_visible,
                    'samples': samples, 'stableFrames': streak,
                }
                (root / 'window-evidence.json').write_text(
                    json.dumps(captured, indent=2), encoding='utf-8')
                moving = len({sample['videoHash'] for sample in samples
                              if sample['coloredFraction'] >= 0.05}) >= 2
                if streak >= 3 and moving:
                    break
                time.sleep(0.15)
            if streak < 3 or not moving:
                raise RuntimeError(
                    f'{kind}: no bounded sequence of stable moving colored video frames')
        if set(captured) == set(WANTED):
            print('Real player-window color verified for H264/HEVC/AV1/VP9')
            return captured
        time.sleep(0.05)
    raise RuntimeError('Window evidence timed out: ' + str(sorted(captured)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=210)
    parser.add_argument('--app', type=Path)
    args = parser.parse_args()
    log_path = args.output.resolve() / 'capture.log'
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log = log_path.open('w', buffering=1)
    sys.stdout = sys.stderr = log
    try:
        capture(args.output, args.timeout, app=args.app)
    except Exception:
        import traceback
        traceback.print_exc()
        raise
    finally:
        log.close()
