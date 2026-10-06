"""Windows production child startup benchmark with synthetic credentials/media.

Measures cold launch (or warm adoption) -> visible window -> sampled colored,
changing pixels. --warm measures from the start signal, after the hidden
engine acknowledges readiness; the prewarm cost is recorded separately.
--prepared emulates the production host's concurrent metadata handoff; it does
not measure the detail-page tap handler or physical audio. All artifacts are
isolated under build/. Requires Pillow and an interactive Windows desktop.
"""

import argparse
import concurrent.futures
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request
import uuid

from PIL import ImageChops, ImageGrab, ImageStat
from player_window_capture import player_window


def write(path, data):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(data), encoding='utf-8')
    temporary.replace(path)


def run(args, root, url, index):
    folder = root / str(index)
    folder.mkdir()
    session = uuid.uuid4().hex
    identity = {'sessionId': session, 'pid': os.getpid()}
    launch = {'itemId': 'baseline', 'autoResume': True,
              'baseUrl': url, 'accessToken': 'synthetic-only',
              'userId': 'validation-user', 'deviceId': 'startup-bench',
              'processDirectory': str(folder), 'processSessionId': session,
              'preparedStartup': args.prepared}
    write(folder / 'launch.json', launch)
    env = dict(os.environ, RILLIGHT_VALIDATION_DIRECTORY=str(folder))
    start = time.perf_counter()
    elapsed = lambda: round((time.perf_counter() - start) * 1000)
    write(folder / 'heartbeat.json', dict(identity, at=int(time.time() * 1000)))

    def fetch(path):
        with urllib.request.urlopen(url + path, timeout=20) as response:
            return json.load(response)

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        if args.warm:
            write(folder / 'launch.json', {'warmPlayer': True,
                  'processDirectory': str(folder), 'processSessionId': session})
        prepared = []
        if args.prepared and not args.warm:
            prepared = [pool.submit(fetch, '/Users/validation-user/Items/baseline'),
                        pool.submit(fetch, '/Users/validation-user')]
        with (folder / 'app.log').open('w', encoding='utf-8') as log:
            child = subprocess.Popen([str(args.executable), 'player', str(folder / 'launch.json')],
                                     cwd=args.executable.parent, env=env, stdout=log, stderr=log)
            result = {'pid': child.pid, 'prepared': args.prepared,
                      'metadataDelayMs': args.metadata_delay_ms}
            first = None
            heartbeat = 0
            try:
                if args.warm:
                    while not (folder / 'ready.json').exists():
                        if child.poll() is not None or elapsed() > 25000:
                            raise RuntimeError('Hidden engine did not become ready')
                        time.sleep(.02)
                    try:
                        player_window(child.pid)
                    except RuntimeError:
                        pass
                    else:
                        raise RuntimeError('Prewarmed player must remain hidden')
                    result['prewarmMs'] = elapsed()
                    (folder / 'ready.json').unlink()
                    start = time.perf_counter()
                    if args.prepared:
                        prepared = [pool.submit(fetch, '/Users/validation-user/Items/baseline'),
                                    pool.submit(fetch, '/Users/validation-user')]
                    write(folder / 'launch.json', launch)
                    write(folder / 'start.json', identity)
                while elapsed() < 30000:
                    if child.poll() is not None:
                        raise RuntimeError('Player exited before visible moving video')
                    if elapsed() - heartbeat >= 500:
                        write(folder / 'heartbeat.json', dict(identity, at=int(time.time() * 1000)))
                        heartbeat = elapsed()
                    if prepared and all(f.done() for f in prepared):
                        write(folder / 'startup.json', dict(identity, itemId='baseline',
                              userId='validation-user', item=prepared[0].result(), user=prepared[1].result()))
                        prepared = []
                    try:
                        user32, hwnd = player_window(child.pid)
                    except RuntimeError:
                        time.sleep(.01)
                        continue
                    if 'visibleMs' not in result:
                        result['visibleMs'] = elapsed()
                        # Sample this synthetic child only, without touching other apps.
                        user32.SetWindowPos(hwnd, -1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010)
                    rect = (ctypes.c_long * 4)()
                    user32.GetWindowRect(hwnd, ctypes.byref(rect))
                    left, top, right, bottom = rect
                    width, height = right - left, bottom - top
                    crop = (left + width // 4, top + height // 4,
                            left + 3 * width // 4, top + 3 * height // 4)
                    shot = ImageGrab.grab(bbox=crop).convert('RGB')
                    sample = shot.resize((80, 45))
                    # Match the fixture's central red/green panels. Merely
                    # finding saturated pixels can mistake the desktop behind
                    # an HWND that is visible but not composited yet for video.
                    pixels = list(sample.get_flattened_data())
                    red = sum(r > 180 and g < 80 and b < 80
                              for i, (r, g, b) in enumerate(pixels) if i % 80 < 40)
                    green = sum(g > 150 and r < 80 and b < 80
                                for i, (r, g, b) in enumerate(pixels) if i % 80 >= 40)
                    fixture_visible = red > 700 and green > 700
                    if fixture_visible and first is None:
                        result['coloredFrameMs'] = elapsed()
                        shot.save(folder / 'first-colored.png')
                        first = sample
                    elif fixture_visible and first is not None and elapsed() - result['coloredFrameMs'] >= 300:
                        difference = sum(ImageStat.Stat(ImageChops.difference(first, sample)).mean) / 3
                        if difference > 1:
                            result['changingFrameMs'] = elapsed()
                            result['meanPixelDifference'] = difference
                            shot.save(folder / 'changed.png')
                            break
                    time.sleep(.02)
                else:
                    raise TimeoutError('No visible changing video within 30 seconds')
            finally:
                write(folder / 'close.json', identity)
                try:
                    child.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            write(folder / 'result.json', result)
            return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', type=Path, required=True)
    parser.add_argument('--media', type=Path, default=Path('build/player-validation/media'))
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--metadata-delay-ms', type=int, default=0)
    parser.add_argument('--prepared', action='store_true')
    parser.add_argument('--warm', action='store_true')
    args = parser.parse_args()
    args.executable = args.executable.resolve()
    root = args.out.resolve()
    root.mkdir(parents=True, exist_ok=False)
    with (root / 'server.log').open('w', encoding='utf-8') as log:
        server = subprocess.Popen([sys.executable, str(Path(__file__).with_name('player_fixtures.py')),
                                   '--media', str(args.media.resolve()), '--output', str(root),
                                   '--metadata-delay-ms', str(args.metadata_delay_ms)],
                                  stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 15
            while not (root / 'server.json').exists():
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('Synthetic server failed to start')
                time.sleep(.05)
            url = json.loads((root / 'server.json').read_text())['url']
            results = []
            for index in range(args.runs):
                result = run(args, root, url, index)
                results.append(result)
                print(json.dumps(result), flush=True)
            write(root / 'summary.json', results)
        finally:
            server.terminate()
            server.wait(timeout=10)
