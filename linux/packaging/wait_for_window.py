"""Find a live X11 window belonging to the expected executable."""
import argparse
import os
import subprocess
import time


def find_window(match, pattern, executable, timeout=30):
    deadline = time.monotonic() + timeout

    def query(*args):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return []
        try:
            result = subprocess.run(
                ['xdotool', *args], capture_output=True, text=True,
                timeout=min(2, remaining), check=False)
        except subprocess.TimeoutExpired:
            return []
        # X11 windows can disappear during search or PID lookup. Discard the
        # incomplete result and retry, while keeping the overall deadline.
        return result.stdout.split() if result.returncode == 0 else []

    while time.monotonic() < deadline:
        for window in query('search', '--onlyvisible', '--' + match, pattern):
            if not window.isdecimal():
                continue
            pids = query('getwindowpid', window)
            if len(pids) != 1 or not pids[0].isdecimal():
                continue
            try:
                actual = os.readlink('/proc/' + pids[0] + '/exe')
            except OSError:
                continue
            if actual == executable:
                return window, pids[0]
        time.sleep(min(0.1, max(0, deadline - time.monotonic())))
    raise RuntimeError(f'No live {executable} window within {timeout}s')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--match', choices=['class', 'name'], required=True)
    parser.add_argument('--pattern', required=True)
    parser.add_argument('--executable', required=True)
    parser.add_argument('--timeout', type=float, default=30)
    args = parser.parse_args()
    print(*find_window(args.match, args.pattern, args.executable, args.timeout))
