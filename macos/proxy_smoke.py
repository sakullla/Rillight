"""Execute the real Dart proxy in signed Release sandbox apps, with a control."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

from sign_bundle import sign


def run_app(app, output, denied):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    environment = {**os.environ, 'RILLIGHT_MACOS_EXPECT_SERVER_DENIED': '1' if denied else '0'}
    mode = 'without-server' if denied else 'release-rights'
    # Launch the signed Mach-O, not a dart/python proxy outside the sandbox.
    result = subprocess.run([str(executable)], env=environment,
                            capture_output=True, text=True, timeout=45)
    (output / (mode + '.stdout.log')).write_text(result.stdout)
    (output / (mode + '.stderr.log')).write_text(result.stderr)
    marker = 'RILLIGHT_MACOS_PROXY_SMOKE '
    reports = [json.loads(line.split(marker, 1)[1]) for line in result.stdout.splitlines()
               if marker in line]
    if result.returncode != 0 or reports != [{'passed': True, 'serverDenied': denied}]:
        raise RuntimeError(f'{mode}: signed sandbox proxy failed ({result.returncode}); see {output}')
    return {'mode': mode, 'exitCode': result.returncode, **reports[0]}


def smoke(app, output):
    app, output = Path(app).resolve(), Path(output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    sign(app)
    results = [run_app(app, output, False)]
    with tempfile.TemporaryDirectory(prefix='rillight-proxy-negative-') as directory:
        negative = Path(directory) / app.name
        subprocess.check_call(['ditto', str(app), str(negative)])
        sign(negative, without_server_for_test=True)
        results.append(run_app(negative, output, True))
    (output / 'result.json').write_text(json.dumps({'passed': True, 'checks': results}, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app')
    parser.add_argument('output')
    args = parser.parse_args()
    smoke(args.app, args.output)
