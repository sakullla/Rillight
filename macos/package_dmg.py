"""Build a drag-install UDZO disk image with the app and Applications."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

VOLUME = 'Rillight'
APP_NAME = 'rillight.app'
APPLICATIONS = 'Applications'


def require_app(app):
    app = Path(app).resolve()
    if app.name != APP_NAME or app.suffix != '.app' or not (app / 'Contents/MacOS').is_dir():
        raise ValueError('Expected an existing rillight.app bundle')
    return app


def inspect_layout(root):
    """Require a visible app plus /Applications shortcut; reject app-only images."""
    root = Path(root)
    app = root / APP_NAME
    shortcut = root / APPLICATIONS
    if not app.is_dir() or not (app / 'Contents/MacOS').is_dir():
        raise ValueError('Disk image is missing rillight.app')
    if not shortcut.is_symlink() or os.readlink(shortcut) != '/Applications':
        raise ValueError('Disk image must include a visible Applications shortcut')
    visible = [path.name for path in root.iterdir() if not path.name.startswith('.')]
    extras = [name for name in visible if name not in {APP_NAME, APPLICATIONS}]
    if extras:
        raise ValueError('Unexpected visible disk image contents: ' + ', '.join(sorted(extras)))
    return {'app': app, 'applications': shortcut}


def stage(app, staging):
    app = require_app(app)
    staging = Path(staging)
    staging.mkdir(parents=True, exist_ok=True)
    destination = staging / APP_NAME
    # ditto keeps the already ad-hoc signature; copytree can drop it.
    subprocess.check_call(['ditto', str(app), str(destination)])
    shortcut = staging / APPLICATIONS
    if shortcut.is_symlink() or shortcut.is_file():
        shortcut.unlink()
    elif shortcut.exists():
        raise ValueError('Applications must be a shortcut, not a folder')
    shortcut.symlink_to('/Applications')
    return inspect_layout(staging)


def package(app, output):
    require_app(app)
    output = Path(output)
    if output.suffix != '.dmg':
        raise ValueError('Expected a .dmg output path')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='rillight-dmg-') as directory:
        staging = Path(directory)
        stage(app, staging)
        subprocess.check_call([
            'hdiutil', 'create', '-volname', VOLUME, '-srcfolder', str(staging),
            '-ov', '-format', 'UDZO', str(output),
        ])
    if not output.is_file():
        raise ValueError('hdiutil did not produce a disk image')
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app')
    parser.add_argument('output')
    args = parser.parse_args()
    print(package(args.app, args.output))
