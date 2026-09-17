"""Assert real X11 player-window video, not just successful control messages.

The validation target and synthetic media are mandatory. Samples require color
inside the child window's video region, excluding controls and window chrome.
"""
import argparse
import json
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import time
from datetime import datetime

from PIL import Image

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--executable', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--timeout', type=float, default=210)
args = parser.parse_args()
root, executable = args.output.resolve(), args.executable.resolve()
wanted = {'1080p60-loaded', '4k-hevc-loaded', 'av1-loaded', 'vp9-loaded'}
captured = {}
deadline = time.monotonic() + args.timeout

def records():
    path = root / 'player.jsonl'
    if not path.exists():
        return []
    result = []
    for line in path.read_text(encoding='utf-8').splitlines():
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError:
            pass  # An append may still be in progress.
    return result

while time.monotonic() < deadline:
    events = records()
    started = next((e for e in events if e['event'] == 'production-main'), None)
    if not started:
        time.sleep(0.05)
        continue
    pid = started['value']['pid']
    process = Path('/proc') / str(pid)
    if not (process / 'exe').exists():
        break
    if (process / 'exe').resolve() != executable:
        raise RuntimeError('Validation PID no longer belongs to the player')
    environment = dict(value.split(b'=', 1) for value in (process / 'environ').read_bytes().split(b'\0') if b'=' in value)
    display_env = {**os.environ, **{key.decode(): environment[key].decode() for key in [b'DISPLAY', b'XAUTHORITY'] if key in environment}}
    for event in events:
        kind = event['event']
        if kind not in wanted or kind in captured:
            continue
        began = time.monotonic()
        loaded_at = datetime.fromisoformat(event['at']).timestamp()
        samples, streak, first_visible = [], 0, None
        # Allow at most 3s to first presentation, then a bounded interval to
        # confirm consecutive frames. The fixture's Linux hold is six seconds.
        while time.monotonic() - began < (3 if first_visible is None else 4):
            latest = next((e['event'] for e in reversed(records()) if e['event'].endswith('-loaded')), kind)
            if latest != kind:
                raise RuntimeError(f'{kind}: source changed before stable video was verified ({latest})')
            windows = subprocess.check_output(['xdotool', 'search', '--onlyvisible', '--pid', str(pid)], env=display_env, text=True).split()
            candidates = []
            for window in windows:
                geometry = subprocess.check_output(['xdotool', 'getwindowgeometry', '--shell', window], env=display_env, text=True)
                values = dict(line.split('=', 1) for line in geometry.splitlines() if '=' in line)
                width, height = int(values['WIDTH']), int(values['HEIGHT'])
                if width >= 400 and height >= 200:
                    candidates.append((width * height, window))
            if not candidates:
                raise RuntimeError('No visible player window for ' + kind)
            window = max(candidates)[1]
            raw = root / (kind + '-' + str(len(samples)) + '.xwd')
            subprocess.check_call(['xwd', '-silent', '-id', window, '-out', str(raw)], env=display_env)
            data = raw.read_bytes()
            header = struct.unpack('>25I', data[:100])
            if header[1] != 7 or header[7] != 0 or header[11] not in (24, 32) or header[14:17] != (0xff0000, 0xff00, 0xff):
                raise RuntimeError('Unsupported XWD layout; cannot claim image verification')
            pixels = data[header[0] + header[19] * 12:]
            image = Image.frombytes('RGB', (header[4], header[5]), pixels, 'raw', 'BGRX' if header[11] == 32 else 'BGR', header[12], 1)
            image.save(root / (kind + '-' + str(len(samples)) + '-window.png'))
            raw.unlink()
            w, h = image.size
            video = image.crop((int(w*.15), int(h*.2), int(w*.85), int(h*.75))).resize((160, 90))
            colors = list(video.getdata())
            fraction = sum(max(rgb) - min(rgb) > 50 and max(rgb) > 80 for rgb in colors) / len(colors)
            elapsed = time.time() - loaded_at
            video_hash = hashlib.sha256(video.tobytes()).hexdigest()
            samples.append({'elapsedSeconds': elapsed, 'coloredFraction': fraction, 'videoHash': video_hash})
            if fraction >= 0.05:
                if first_visible is None:
                    first_visible = elapsed
                streak += 1
            else:
                streak = 0
            captured[kind] = {'pid': pid, 'window': window, 'size': image.size,
                              'firstVisibleSeconds': first_visible, 'samples': samples,
                              'stableFrames': streak}
            (root / 'window-evidence.json').write_text(json.dumps(captured, indent=2), encoding='utf-8')
            moving = len({sample['videoHash'] for sample in samples if sample['coloredFraction'] >= 0.05}) >= 2
            if streak >= 3 and moving:
                break
            time.sleep(0.15)
        if streak < 3 or not moving:
            raise RuntimeError(f'{kind}: no bounded sequence of stable moving colored video frames')
        # Preserve actual virtual-output activity, separately from decoded
        # audio parameters. This is not physical-speaker verification.
        audio = subprocess.check_output(['pactl', 'list', 'sink-inputs'], text=True)
        (root / (kind + '-audio.txt')).write_text(audio, encoding='utf-8')
        if f'application.process.id = "{pid}"' not in audio:
            raise RuntimeError('Player has no active PulseAudio output for ' + kind)
    if set(captured) == wanted:
        print('Real player-window color and virtual audio output verified for H264/HEVC/AV1/VP9')
        break
    time.sleep(0.05)
else:
    raise RuntimeError('Window evidence timed out: ' + str(sorted(captured)))
if set(captured) != wanted:
    raise RuntimeError('Player exited before all window samples: ' + str(sorted(captured)))
