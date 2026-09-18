"""Portable regression for thin/fat otool output used by native packaging."""
from io import BytesIO
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'packages/rillight_player/native'))
from bundle_macos import otool_dependencies
from prepare_macos import USER_AGENT, download
from sign_bundle import release_entitlements, sign, verify_signed_entitlements


class NativeDownloadTest(unittest.TestCase):
    def test_download_sends_an_explicit_user_agent(self):
        captured = {}

        class Response:
            def __init__(self):
                self._data = BytesIO(b'dylib')

            def read(self, size=-1):
                return self._data.read(size)

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        def urlopen(request, **kwargs):
            captured['headers'] = dict(request.header_items())
            captured['url'] = request.full_url
            return Response()

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
