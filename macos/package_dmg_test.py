"""Regression for drag-install DMG staging; rejects app-only images."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from package_dmg import (
    APP_ICON_POSITION,
    APPLICATIONS_ICON_POSITION,
    BACKGROUND_ASSET,
    ICON_SIZE,
    WINDOW_SIZE,
    inspect_layout,
    package,
    stage,
    write_layout_assets,
)

try:
    import ds_store  # noqa: F401
    HAVE_DS_STORE = True
except ImportError:
    HAVE_DS_STORE = False

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/macos-package.yml'


def make_app(directory, name='rillight.app'):
    app = Path(directory) / name
    (app / 'Contents/MacOS').mkdir(parents=True)
    (app / 'Contents/MacOS/rillight').write_bytes(b'fixture')
    return app


def fake_ditto(command):
    if command[0] != 'ditto':
        raise AssertionError(command)
    shutil.copytree(command[1], command[2])


class DragInstallLayoutTest(unittest.TestCase):
    @unittest.skipUnless(HAVE_DS_STORE, 'ds_store is required to stage the DMG layout')
    def test_staging_includes_app_and_applications_shortcut(self):
        with tempfile.TemporaryDirectory(prefix='rillight-dmg-stage-') as directory:
            app = make_app(directory)
            staging = Path(directory) / 'staging'
            with patch('package_dmg.subprocess.check_call', side_effect=fake_ditto):
                layout = stage(app, staging)
            self.assertTrue((layout['app'] / 'Contents/MacOS/rillight').is_file())
            self.assertTrue(layout['applications'].is_symlink())
            self.assertEqual(os.readlink(layout['applications']), '/Applications')
            self.assertEqual(
                {path.name for path in staging.iterdir() if not path.name.startswith('.')},
                {'rillight.app', 'Applications'})

    def test_app_only_layout_is_not_a_release_image(self):
        with tempfile.TemporaryDirectory(prefix='rillight-dmg-app-only-') as directory:
            staging = Path(directory)
            make_app(staging)
            with self.assertRaisesRegex(ValueError, 'Applications shortcut'):
                inspect_layout(staging)

    def test_copied_applications_folder_is_not_a_shortcut(self):
        with tempfile.TemporaryDirectory(prefix='rillight-dmg-folder-') as directory:
            staging = Path(directory)
            make_app(staging)
            (staging / 'Applications').mkdir()
            with self.assertRaisesRegex(ValueError, 'Applications shortcut'):
                inspect_layout(staging)

    def test_wrong_applications_target_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='rillight-dmg-target-') as directory:
            staging = Path(directory)
            make_app(staging)
            (staging / 'Applications').symlink_to('/Users')
            with self.assertRaisesRegex(ValueError, 'Applications shortcut'):
                inspect_layout(staging)


class LayoutAssetsTest(unittest.TestCase):
    """The hidden Finder layout assets must not leak into the visible set."""

    @unittest.skipUnless(HAVE_DS_STORE, 'ds_store is required to write the Finder layout')
    def test_staging_writes_hidden_background_and_ds_store(self):
        with tempfile.TemporaryDirectory(prefix='rillight-dmg-assets-') as directory:
            staging = Path(directory)
            write_layout_assets(staging, BACKGROUND_ASSET)
            self.assertEqual(
                {path.name for path in staging.iterdir()},
                {'.background', '.DS_Store'})
            self.assertEqual(
                (staging / '.background' / 'background.png').read_bytes(),
                BACKGROUND_ASSET.read_bytes())
            from ds_store import DSStore
            with DSStore.open(str(staging / '.DS_Store')) as store:
                self.assertEqual(store['rillight.app']['Iloc'], APP_ICON_POSITION)
                self.assertEqual(store['Applications']['Iloc'], APPLICATIONS_ICON_POSITION)
                self.assertNotEqual(APP_ICON_POSITION, APPLICATIONS_ICON_POSITION)
                self.assertEqual(store['.']['icvp']['iconSize'], float(ICON_SIZE))
                self.assertIn('{%d, %d}' % WINDOW_SIZE, store['.']['bwsp']['WindowBounds'])
                self.assertEqual(store['.']['icvp']['backgroundType'], 2)

    def test_missing_background_asset_fails_the_stage(self):
        with tempfile.TemporaryDirectory(prefix='rillight-dmg-missing-') as directory:
            app = make_app(directory)
            staging = Path(directory) / 'staging'
            absent = Path(directory) / 'absent.png'
            with patch('package_dmg.BACKGROUND_ASSET', absent):
                with self.assertRaisesRegex(ValueError, 'background'):
                    stage(app, staging)
            self.assertFalse(staging.exists())


class PackageCommandTest(unittest.TestCase):
    @unittest.skipUnless(HAVE_DS_STORE, 'ds_store is required to stage the DMG layout')
    def test_hdiutil_packs_udzo_from_drag_install_staging(self):
        commands = []

        def execute(command):
            commands.append(command)
            if command[0] == 'ditto':
                fake_ditto(command)
                return
            self.assertEqual(command[0], 'hdiutil')
            self.assertEqual(command[1], 'create')
            src = Path(command[command.index('-srcfolder') + 1])
            inspect_layout(src)
            self.assertEqual(command[command.index('-volname') + 1], 'Rillight')
            self.assertEqual(command[command.index('-format') + 1], 'UDZO')
            self.assertIn('-ov', command)
            Path(command[-1]).write_bytes(b'UDZO')

        with tempfile.TemporaryDirectory(prefix='rillight-dmg-pkg-') as directory:
            app = make_app(directory)
            output = Path(directory) / 'Rillight-macos-v0.0.0-test-signed.dmg'
            with patch('package_dmg.subprocess.check_call', side_effect=execute):
                self.assertEqual(package(app, output), output)
            self.assertTrue(output.is_file())
        self.assertEqual([command[0] for command in commands], ['ditto', 'hdiutil'])
        joined = ' '.join(' '.join(command) for command in commands)
        self.assertNotIn('codesign', joined)
        self.assertNotIn('notarytool', joined)
        self.assertNotIn('staple', joined)
        self.assertNotIn('Developer ID', joined)

    def test_non_release_app_name_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='rillight-dmg-name-') as directory:
            app = make_app(directory, 'Other.app')
            with self.assertRaisesRegex(ValueError, 'rillight.app'):
                package(app, Path(directory) / 'out.dmg')


class ReleaseWorkflowTest(unittest.TestCase):
    def test_github_macos_artifact_uses_drag_install_helper(self):
        workflow = WORKFLOW.read_text(encoding='utf-8')
        helper = Path(__file__).with_name('package_dmg.py').read_text(encoding='utf-8')
        self.assertIn('python3 macos/package_dmg.py', workflow)
        self.assertIn('python3 macos/package_dmg_test.py', workflow)
        self.assertIn('python3 -m pip install ds_store==', workflow)
        self.assertIn('- name: Sign, verify and package', workflow)
        self.assertNotIn('Ad-hoc sign', workflow)
        self.assertIn('Rillight-macos-${BUILD_VERSION}-$(uname -m)-${suffix}.dmg', workflow)
        self.assertIn('suffix="signed"', workflow)
        self.assertIn('suffix="adhoc"', workflow)
        self.assertNotIn('notarytool', workflow)
        self.assertNotIn('Developer ID', workflow)
        self.assertNotIn('staple', workflow)
        self.assertNotIn('ditto "$app" "$staging/rillight.app"', workflow)
        self.assertIn('dmg_assets', helper)
        self.assertIn('background_alias_bytes', helper)
        self.assertNotIn('notarytool', helper)
        self.assertNotIn('Developer ID', helper)
        self.assertNotIn('staple', helper)
        self.assertNotIn('codesign', helper)


@unittest.skipUnless(sys.platform == 'darwin', 'hdiutil is a macOS tool')
class AttachedImageTest(unittest.TestCase):
    @unittest.skipUnless(HAVE_DS_STORE, 'ds_store is required to stage the DMG layout')
    def test_attached_image_shows_app_and_applications(self):
        with tempfile.TemporaryDirectory(prefix='rillight-dmg-attach-') as directory:
            directory = Path(directory)
            app = make_app(directory)
            image = directory / 'Rillight-macos-test-signed.dmg'
            package(app, image)
            mount = directory / 'mnt'
            mount.mkdir()
            subprocess.check_call(
                ['hdiutil', 'attach', '-nobrowse', '-readonly', '-mountpoint',
                 str(mount), str(image)])
            try:
                layout = inspect_layout(mount)
                self.assertTrue((layout['app'] / 'Contents/MacOS/rillight').is_file())
                self.assertEqual(os.readlink(layout['applications']), '/Applications')
                self.assertTrue((mount / '.background' / 'background.png').is_file())
                self.assertTrue((mount / '.DS_Store').is_file())
            finally:
                subprocess.check_call(['hdiutil', 'detach', str(mount), '-force'])


if __name__ == '__main__':
    unittest.main()
