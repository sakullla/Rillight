"""Portable regression for thin/fat otool output used by native packaging."""
from io import BytesIO
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'packages/rillight_player/native'))
import prepare_macos
from bundle_macos import otool_dependencies
from prepare_macos import FILELIST_URL, USER_AGENT, download, parse_filelist, prepare_dylibs
from sign_bundle import release_entitlements, sign, verify_signed_entitlements

FAT = b'\xca\xfe\xba\xbe' + b'\x00\x00\x00\x02' + b'\x00' * 24
ROOT = Path(__file__).resolve().parents[1]


class FakeResponse:
    def __init__(self, data, headers=None):
        self._data = BytesIO(data)
        self.headers = headers or {}

    def read(self, size=-1):
        return self._data.read(size)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class NativeDownloadTest(unittest.TestCase):
    def test_download_sends_an_explicit_user_agent(self):
        captured = {}

        def urlopen(request, **kwargs):
            captured['headers'] = dict(request.header_items())
            captured['url'] = request.full_url
            return FakeResponse(b'dylib')

        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'libogg.0.dylib'
            with patch('prepare_macos.urllib.request.urlopen', side_effect=urlopen):
                download('https://iina.io/dylibs/universal/libogg.0.dylib', target)
            self.assertEqual(target.read_bytes(), b'dylib')
        self.assertEqual(captured['url'], 'https://iina.io/dylibs/universal/libogg.0.dylib')
        headers = {key.lower(): value for key, value in captured['headers'].items()}
        self.assertEqual(headers['user-agent'], USER_AGENT)

    def test_python_urllib_without_user_agent_is_the_known_403_path(self):
        self.assertNotIn('Python-urllib', USER_AGENT)
        self.assertTrue(USER_AGENT.startswith('Rillight/'))

    def test_manifest_does_not_pin_iina_dylib_hashes(self):
        manifest = json.loads((ROOT / 'packages/rillight_player/native/dependencies.json').read_text())
        self.assertNotIn('files', manifest['macos'])
        self.assertNotIn('sha256', json.dumps(manifest['macos']))
        self.assertEqual(manifest['macos']['dylibs_url'], 'https://iina.io/dylibs/universal')
        self.assertEqual(manifest['macos']['filelist_url'], FILELIST_URL)

    def test_filelist_requires_libmpv_and_rejects_paths(self):
        names = parse_filelist('libogg.0.dylib\nlibmpv.2.dylib\nlibogg.0.dylib\n')
        self.assertEqual(names, ['libogg.0.dylib', 'libmpv.2.dylib'])
        with self.assertRaisesRegex(RuntimeError, 'missing libmpv.2.dylib'):
            parse_filelist('libogg.0.dylib\n')
        with self.assertRaisesRegex(RuntimeError, 'Invalid IINA file list entry'):
            parse_filelist('../libmpv.2.dylib\n')

    def test_prepare_follows_live_filelist_without_sha256(self):
        requested = []
        payloads = {
            FILELIST_URL: b'libmpv.2.dylib\nlibogg.0.dylib\n',
            'https://iina.io/dylibs/universal/libmpv.2.dylib': FAT + b'mpv',
            'https://iina.io/dylibs/universal/libogg.0.dylib': FAT + b'ogg',
        }

        def urlopen(request, **kwargs):
            requested.append(request.full_url)
            headers = {key.lower(): value for key, value in request.header_items()}
            self.assertEqual(headers['user-agent'], USER_AGENT)
            return FakeResponse(payloads[request.full_url], {'ETag': '"live"'})

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            leftover = root / 'macos/Libraries/libarchive.13.dylib'
            leftover.parent.mkdir(parents=True)
            leftover.write_bytes(FAT + b'stale')
            with patch.object(prepare_macos, 'ROOT', root), \
                    patch.dict(os.environ, {'RILLIGHT_NATIVE_CACHE': str(root / 'cache')}), \
                    patch('prepare_macos.urllib.request.urlopen', side_effect=urlopen):
                prepare_dylibs()
            libraries = root / 'macos/Libraries'
            self.assertEqual((libraries / 'libmpv.2.dylib').read_bytes(), FAT + b'mpv')
            self.assertEqual((libraries / 'libogg.0.dylib').read_bytes(), FAT + b'ogg')
            self.assertFalse(leftover.exists())
        self.assertEqual(requested[0], FILELIST_URL)
        self.assertIn('https://iina.io/dylibs/universal/libmpv.2.dylib', requested)

    def test_non_macho_download_is_rejected(self):
        payloads = {
            FILELIST_URL: b'libmpv.2.dylib\n',
            'https://iina.io/dylibs/universal/libmpv.2.dylib': b'<!doctype html>',
        }

        def urlopen(request, **kwargs):
            return FakeResponse(payloads[request.full_url])

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(prepare_macos, 'ROOT', root), \
                    patch.dict(os.environ, {'RILLIGHT_NATIVE_CACHE': str(root / 'cache')}), \
                    patch('prepare_macos.urllib.request.urlopen', side_effect=urlopen):
                with self.assertRaisesRegex(RuntimeError, 'universal Mach-O'):
                    prepare_dylibs()


class OtoolDependenciesTest(unittest.TestCase):
    def test_thin_file_title_is_not_a_build_machine_dependency(self):
        output = '/Users/runner/work/Rillight.app/Contents/Frameworks/libmpv.2.dylib:\n' \
                 '\t@rpath/libmpv.2.dylib (compatibility version 2.0.0, current version 2.5.0)\n' \
                 '\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1292.60.1)\n'
        self.assertEqual(otool_dependencies(output), ['@rpath/libmpv.2.dylib', '/usr/lib/libSystem.B.dylib'])

    def test_fat_architecture_titles_are_not_dependencies(self):
        output = ''.join(
            f'/Users/runner/app/libmpv.2.dylib (architecture {arch}):\n'
            '\t@rpath/libavcodec.63.dylib (compatibility version 63.0.0, current version 63.1.100)\n'
            for arch in ['x86_64', 'arm64'])
        self.assertEqual(otool_dependencies(output), ['@rpath/libavcodec.63.dylib'] * 2)

    def test_real_nonportable_dependencies_remain_visible_to_audit(self):
        output = '/Users/runner/libmpv.2.dylib:\n' \
                 '\t/Users/builder/lib/libbad.dylib (compatibility version 1.0.0, current version 1.0.0)\n'
        self.assertEqual(otool_dependencies(output), ['/Users/builder/lib/libbad.dylib'])


class ReleaseSigningTest(unittest.TestCase):
    def test_release_retains_all_three_required_rights(self):
        expected = release_entitlements()
        for key in ('app-sandbox', 'network.client', 'network.server'):
            self.assertIs(expected['com.apple.security.' + key], True)

    def test_missing_server_in_release_configuration_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Release.entitlements'
            expected = release_entitlements()
            del expected['com.apple.security.network.server']
            path.write_bytes(plistlib.dumps(expected))
            with self.assertRaisesRegex(ValueError, 'network server'):
                release_entitlements(path)

    def test_signature_validity_does_not_hide_lost_entitlements(self):
        expected = release_entitlements()
        actual = {**expected, 'com.apple.security.network.server': False}
        with patch('sign_bundle.subprocess.check_output', return_value=plistlib.dumps(actual)):
            with self.assertRaisesRegex(ValueError, 'Signed entitlements differ'):
                verify_signed_entitlements('rillight.app', expected)

    def test_app_rights_are_not_applied_to_nested_libraries(self):
        self.check_signing(False)

    def test_negative_control_removes_only_server_and_keeps_sandbox(self):
        self.check_signing(True)

    def check_signing(self, negative):
        expected = release_entitlements()
        if negative:
            expected.pop('com.apple.security.network.server')
        commands = []

        def execute(command):
            commands.append(command)
            if '--entitlements' in command:
                path = Path(command[command.index('--entitlements') + 1])
                self.assertEqual(plistlib.loads(path.read_bytes()), expected)

        def output(command, **kwargs):
            if '--verbose=4' in command:
                return 'Executable=rillight\nSignature=adhoc\n'
            return plistlib.dumps(expected)

        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'rillight.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            framework = app / 'Contents/Frameworks/Plugin.framework'
            framework.mkdir(parents=True)
            library = app / 'Contents/Frameworks/libmpv.2.dylib'
            library.write_bytes(b'fixture')
            with patch('sign_bundle.subprocess.check_call', side_effect=execute), \
                 patch('sign_bundle.subprocess.check_output', side_effect=output):
                sign(app, without_server_for_test=negative)
            signing = [command for command in commands if '--sign' in command]
            self.assertEqual(len(signing), 3)
            self.assertTrue(all('--entitlements' not in c and '--deep' not in c for c in signing[:-1]))
            self.assertEqual(signing[-1][-1], str(app.resolve()))
            self.assertIn('--entitlements', signing[-1])
            self.assertNotIn('--deep', signing[-1])


if __name__ == '__main__':
    unittest.main()
