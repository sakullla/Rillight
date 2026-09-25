"""Build a drag-install UDZO disk image with the app and Applications."""
import argparse
import datetime
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

VOLUME = 'Rillight'
APP_NAME = 'rillight.app'
APPLICATIONS = 'Applications'
WINDOW_SIZE = (660, 400)
ICON_SIZE = 128
APP_ICON_POSITION = (160, 200)
APPLICATIONS_ICON_POSITION = (500, 200)
BACKGROUND_ASSET = Path(__file__).resolve().parent / 'dmg_assets' / 'background.png'
BACKGROUND_DIRECTORY = '.background'
BACKGROUND_NAME = 'background.png'


def require_app(app):
    app = Path(app).resolve()
    if app.name != APP_NAME or app.suffix != '.app' or not (app / 'Contents/MacOS').is_dir():
        raise ValueError('Expected an existing rillight.app bundle')
    return app


def require_background():
    """Refuse to ship a bare-window image when the brand background is absent."""
    if not BACKGROUND_ASSET.is_file():
        raise ValueError(
            'Missing DMG background asset: %s (regenerate with: '
            'python tool/generate_app_icons.py --dmg-background --force)' % BACKGROUND_ASSET)
    return BACKGROUND_ASSET


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


def background_alias_bytes():
    """Alias record for <volume>/.background/background.png inside the mounted image."""
    from mac_alias import (
        ALIAS_FIXED_DISK, ALIAS_KIND_FILE, ALIAS_NO_CNID, Alias, TargetInfo, VolumeInfo,
    )
    epoch = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)
    volume = VolumeInfo(
        name=VOLUME, creation_date=epoch, fs_type=b'H+',
        disk_type=ALIAS_FIXED_DISK, attribute_flags=0, fs_id=b'\0\0')
    target = TargetInfo(
        kind=ALIAS_KIND_FILE, filename=BACKGROUND_NAME,
        folder_cnid=ALIAS_NO_CNID, cnid=ALIAS_NO_CNID, creation_date=epoch,
        creator_code=b'\0\0\0\0', type_code=b'\0\0\0\0',
        folder_name=BACKGROUND_DIRECTORY,
        carbon_path='%s:%s:%s' % (VOLUME, BACKGROUND_DIRECTORY, BACKGROUND_NAME),
        posix_path='%s/%s' % (BACKGROUND_DIRECTORY, BACKGROUND_NAME))
    return Alias(volume=volume, target=target).to_bytes()


def write_ds_store(path):
    """Write the Finder icon-view layout: fixed window, both icons positioned."""
    from ds_store import DSStore
    with DSStore.open(str(path), 'w+') as store:
        store['.']['vSrn'] = ('long', 1)
        store['.']['bwsp'] = {
            'WindowBounds': '{{100, 100}, {%d, %d}}' % WINDOW_SIZE,
            'ShowStatusBar': False,
            'ShowSidebar': False,
            'ShowTabView': False,
            'ShowToolbar': False,
            'ShowPathbar': False,
            'ContainerShowSidebar': False,
            'PreviewPaneVisibility': False,
            'SidebarWidth': 180,
        }
        store['.']['icvp'] = {
            'viewOptionsVersion': 1,
            'arrangeBy': 'none',
            'iconSize': float(ICON_SIZE),
            'backgroundType': 2,
            'backgroundImageAlias': background_alias_bytes(),
            'gridOffsetX': 0.0,
            'gridOffsetY': 0.0,
            'gridSpacing': 100.0,
            'scrollPositionX': 0.0,
            'scrollPositionY': 0.0,
            'showIconPreview': True,
            'showItemInfo': False,
            'labelOnBottom': True,
            'textSize': 12.0,
            'backgroundColorRed': 1.0,
            'backgroundColorGreen': 1.0,
            'backgroundColorBlue': 1.0,
        }
        store[APP_NAME]['Iloc'] = APP_ICON_POSITION
        store[APPLICATIONS]['Iloc'] = APPLICATIONS_ICON_POSITION


def write_layout_assets(staging, background):
    """Stage the hidden Finder layout assets next to the visible icons."""
    hidden = Path(staging) / BACKGROUND_DIRECTORY
    hidden.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(background, hidden / BACKGROUND_NAME)
    write_ds_store(Path(staging) / '.DS_Store')


def stage(app, staging):
    app = require_app(app)
    background = require_background()
    staging = Path(staging)
    staging.mkdir(parents=True, exist_ok=True)
    destination = staging / APP_NAME
    # ditto keeps the already ad-hoc signature; copytree can drop it.
    subprocess.check_call(['ditto', str(app), str(destination)])
    write_layout_assets(staging, background)
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
