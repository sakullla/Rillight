"""Stage and sign the player executable with inherited App Sandbox rights."""

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

HELPER_NAME = 'rillight_player'
ENTITLEMENTS = {
    'com.apple.security.app-sandbox': True,
    'com.apple.security.inherit': True,
}


def helper_path(app):
    return Path(app) / 'Contents/MacOS' / HELPER_NAME


def verify_helper(app):
    helper = helper_path(app)
    if not helper.is_file():
        raise RuntimeError('Missing sandbox-inheriting player helper')
    actual = plistlib.loads(subprocess.check_output(
        ['codesign', '--display', '--entitlements', ':-', str(helper)]))
    if actual != ENTITLEMENTS:
        raise RuntimeError('Player helper must only inherit the app sandbox')
    subprocess.check_call(['codesign', '--verify', '--strict', str(helper)])


def sign_helper(app, identity='-'):
    helper = helper_path(app)
    if not helper.is_file():
        raise RuntimeError('Missing sandbox-inheriting player helper')
    with tempfile.TemporaryDirectory(prefix='rillight-player-entitlements-') as directory:
        entitlements = Path(directory) / 'Player.entitlements'
        entitlements.write_bytes(plistlib.dumps(ENTITLEMENTS))
        subprocess.check_call([
            'codesign', '--force', '--sign', identity, '--timestamp=none',
            '--entitlements', str(entitlements), str(helper)])
    verify_helper(app)


def stage_helper(app, executable):
    app = Path(app).resolve()
    source = app / 'Contents/MacOS' / executable
    if Path(executable).name != executable or executable == HELPER_NAME or not source.is_file():
        raise RuntimeError('Missing or invalid main executable for player helper')
    # Keep the sibling location: Cocoa/Flutter use the same app resources, and
    # @executable_path/../Frameworks continues to resolve bundled libraries.
    shutil.copyfile(source, helper_path(app))
    shutil.copymode(source, helper_path(app))
    sign_helper(app, os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('executable')
    args = parser.parse_args()
    stage_helper(args.app, args.executable)
