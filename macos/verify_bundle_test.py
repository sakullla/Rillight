"""Portable regressions for owned-core macOS provenance and bundle checks."""

import hashlib
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'packages/rillight_player/native'))
import prepare_macos
from bundle_macos import NATIVE_LICENSES, audit_binary, bundle, otool_dependencies
from sign_bundle import release_entitlements, sign, verify_signed_entitlements
from verify_bundle import deployment_versions, verify


NAMES = ['libavformat.61.dylib', 'libavcodec.61.dylib',
         'libavutil.59.dylib', 'libavfilter.10.dylib',
         'libswresample.5.dylib', 'libswscale.8.dylib',
         'libass.9.dylib', 'libdav1d.7.dylib']


def sha(data):
    return hashlib.sha256(data).hexdigest()


class PreparedFixture:
    def __init__(self, temporary):
        self.root = Path(temporary)
        self.prefix = self.root / 'sdk'
        self.core = self.root / 'core/librillight_core.dylib'
        self.core.parent.mkdir(parents=True)
        self.core.write_bytes(b'owned-core')
        self.marker = {
            'platform': 'macos-universal',
            'ffmpeg_version': 'n9.0.1',
            'ffmpeg_commit': 'locked-ffmpeg',
            'ffmpeg_tag': 'n9.0.1',
            'ffmpeg_patches': {'patch': 'sha'},
            'libraries': {},
            'libass': {'version': '0.17.5', 'commit': 'locked-ass',
                       'library': 'lib/libass.9.dylib'},
        }
        for name in NAMES:
            path = self.prefix / 'lib' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
            self.marker['libraries']['lib/' + name] = sha(path.read_bytes())
        (self.prefix / 'rillight-core-dependencies.json').write_text(
            json.dumps(self.marker), encoding='utf-8')
        (self.root / 'native/core').mkdir(parents=True)
        (self.root / 'native/core/rillight_core.h').write_text(
            '#define RILLIGHT_CORE_ABI_VERSION 7\n', encoding='utf-8')
        (self.root / 'native/core_dependencies.json').write_text(
            json.dumps({'ffmpeg': {'version': 'n9.0.1',
                                   'commit': 'locked-ffmpeg',
                                   'patches': {'patch': 'sha'}},
                        'libass': {'commit': 'locked-ass'}}), encoding='utf-8')
        (self.root / 'THIRD_PARTY_NOTICES.md').write_text('FFmpeg/libass', encoding='utf-8')
        licenses = self.root / 'native/licenses'
        licenses.mkdir()
        for name in NATIVE_LICENSES:
            (licenses / name).write_text('license', encoding='utf-8')


class PrepareTest(unittest.TestCase):
    def test_missing_explicit_inputs_fails_without_download(self):
        with patch.dict('os.environ', {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, 'Set RILLIGHT_MACOS_CORE_PREFIX'):
                prepare_macos.prepare()

    def test_universal_hashed_closure_stages_only_sdk_runtime_dylibs(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = PreparedFixture(temp)
            stale = fixture.root / 'macos/Libraries/libmpv.2.dylib'
            stale.parent.mkdir(parents=True)
            stale.write_bytes(b'old')
            with patch('prepare_macos.verify', return_value=[]), \
                 patch('prepare_macos.architectures', return_value={'x86_64', 'arm64'}):
                record = prepare_macos.prepare(
                    fixture.prefix, fixture.core, sha(b'owned-core'), fixture.root)
            self.assertEqual(record['core_abi'], 7)
            self.assertEqual(set(record['libraries']), set(NAMES + [fixture.core.name]))
            self.assertFalse(stale.exists())
            self.assertEqual((fixture.root / 'macos/Libraries' /
                              prepare_macos.RECORD).is_file(), True)
            self.assertEqual((fixture.root / 'macos/Libraries' /
                              fixture.core.name).read_bytes(), b'owned-core')

    def test_hash_or_missing_architecture_rejects_core(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = PreparedFixture(temp)
            with patch('prepare_macos.verify', return_value=[]):
                with self.assertRaisesRegex(RuntimeError, 'SHA256 mismatch'):
                    prepare_macos.prepare(fixture.prefix, fixture.core, '0' * 64,
                                          fixture.root)
                with patch('prepare_macos.architectures', return_value={'arm64'}):
                    with self.assertRaisesRegex(RuntimeError, 'not universal'):
                        prepare_macos.prepare(fixture.prefix, fixture.core,
                                              sha(b'owned-core'), fixture.root)

    def test_missing_component_and_mpv_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = PreparedFixture(temp)
            marker = fixture.marker
            marker['libraries'].pop('lib/libavcodec.61.dylib')
            with self.assertRaisesRegex(RuntimeError, 'libavcodec'):
                prepare_macos.runtime_paths(fixture.prefix, marker)
            marker['libraries']['lib/libavcodec.61.dylib'] = 'hash'
            path = fixture.prefix / 'lib/libmpv.2.dylib'
            path.write_bytes(b'mpv')
            marker['libraries']['lib/libmpv.2.dylib'] = sha(b'mpv')
            with self.assertRaisesRegex(RuntimeError, 'libmpv'):
                prepare_macos.runtime_paths(fixture.prefix, marker)

    def test_dav1d_marker_library_is_staged_even_if_absent_from_ffmpeg_hashes(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = PreparedFixture(temp)
            marker = fixture.marker
            dav1d = marker['libraries'].pop('lib/libdav1d.7.dylib')
            marker['dav1d'] = {'library': 'lib/libdav1d.7.dylib', 'sha256': dav1d}
            paths = prepare_macos.runtime_paths(fixture.prefix, marker)
            self.assertIn('libdav1d.7.dylib', {path.name for path in paths})


class MachOTest(unittest.TestCase):
    def test_otool_fat_titles_are_not_dependencies(self):
        output = ''.join(
            f'/builder/libavcodec.dylib (architecture {arch}):\n'
            '\t@rpath/libavformat.61.dylib (compatibility version 1.0.0)\n'
            for arch in ('x86_64', 'arm64'))
        self.assertEqual(otool_dependencies(output),
                         ['@rpath/libavformat.61.dylib'] * 2)

    def test_rejects_unbundled_and_legacy_dependencies(self):
        with tempfile.TemporaryDirectory() as temp:
            contents = Path(temp) / 'rillight.app/Contents'
            binary = contents / 'Frameworks/librillight_core.dylib'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'core')
            with patch('bundle_macos.subprocess.check_output',
                       return_value='\t@rpath/libmpv.2.dylib (compatibility version 2)'):
                with self.assertRaisesRegex(RuntimeError, 'Legacy playback'):
                    audit_binary(binary, contents)
            with patch('bundle_macos.subprocess.check_output',
                       return_value='\t@rpath/libmissing.dylib (compatibility version 1)'):
                with self.assertRaisesRegex(RuntimeError, 'unbundled'):
                    audit_binary(binary, contents)

    def test_macos_deployment_parser_handles_both_load_commands(self):
        output = 'cmd LC_BUILD_VERSION\n  minos 12.0\n  sdk 15.0\n' \
                 'cmd LC_VERSION_MIN_MACOSX\n  version 11.0.0\n'
        self.assertEqual(deployment_versions(output), [(12, 0), (11, 0, 0)])


class BundleVerificationTest(unittest.TestCase):
    def test_build_phase_bundles_only_verified_core_libraries(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = PreparedFixture(temp)
            with patch('prepare_macos.verify', return_value=[]), \
                 patch('prepare_macos.architectures', return_value={'x86_64', 'arm64'}):
                record = prepare_macos.prepare(
                    fixture.prefix, fixture.core, sha(b'owned-core'), fixture.root)
            app = fixture.root / 'candidate.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/MacOS/rillight').write_bytes(b'executable')
            with patch.dict('os.environ',
                            {'RILLIGHT_MACOS_CORE_PREFIX': str(fixture.prefix)}), \
                 patch('bundle_macos.audit_binary'), \
                 patch('bundle_macos.subprocess.check_call'):
                result = bundle(app, root=fixture.root, record=record)
            self.assertEqual(set(result['bundled_libraries_sha256']),
                             set(record['libraries']))
            self.assertTrue((app / 'Contents/Frameworks/librillight_core.dylib').is_file())
            self.assertTrue((app / 'Contents/Resources/rillight-native-licenses/'
                             'libass-ISC.txt').is_file())
            self.assertTrue((app / 'Contents/Resources/rillight-native-licenses/'
                             'dav1d-BSD-2-Clause.txt').is_file())
            self.assertTrue((app / 'Contents/Resources/rillight-native-licenses/'
                             'FreeType-FTL.txt').is_file())
            self.assertTrue((app / 'Contents/Resources/rillight-native-licenses/'
                             'HarfBuzz-Old-MIT.txt').is_file())
            self.assertFalse((app / 'Contents/Frameworks/libmpv.2.dylib').exists())

    def make_app(self, root):
        app = root / 'rillight.app'
        contents = app / 'Contents'
        frameworks = contents / 'Frameworks'
        resources = contents / 'Resources'
        executable = contents / 'MacOS/rillight'
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b'executable')
        frameworks.mkdir()
        resources.mkdir()
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'LSMinimumSystemVersion': '12.0', 'CFBundleExecutable': 'rillight'}))
        source_lock = ROOT / 'packages/rillight_player/native/core_dependencies.json'
        (resources / 'rillight-core-source-lock.json').write_bytes(source_lock.read_bytes())
        lock = json.loads(source_lock.read_text(encoding='utf-8'))
        sdk = {'platform': 'macos-universal',
               'ffmpeg_version': lock['ffmpeg']['version'],
               'ffmpeg_commit': lock['ffmpeg']['commit'],
               'libraries': {'lib/' + name: sha(name.encode()) for name in NAMES},
               'libass': {'library': 'lib/libass.9.dylib',
                          'sha256': sha(b'libass.9.dylib')}}
        sdk_path = resources / 'rillight-core-dependencies.json'
        sdk_path.write_text(json.dumps(sdk), encoding='utf-8')
        libraries = {}
        for name in NAMES + ['librillight_core.dylib']:
            path = frameworks / name
            path.write_bytes(name.encode())
            libraries[name] = sha(path.read_bytes())
        record = {
            'schema': 1, 'target': 'macos-universal',
            'core_spec_sha256': sha(source_lock.read_bytes()),
            'sdk_marker_sha256': sha(sdk_path.read_bytes()),
            'ffmpeg_version': lock['ffmpeg']['version'],
            'ffmpeg_commit': lock['ffmpeg']['commit'],
            'ffmpeg_tag': lock['ffmpeg']['version'],
            'ffmpeg_patches': lock['ffmpeg']['patches'],
            'libass_version': lock['libass']['version'],
            'libass_commit': lock['libass']['commit'],
            'libraries': libraries,
            'bundled_libraries_sha256': libraries.copy(),
        }
        record_path = resources / 'rillight-macos-closure.json'
        record_path.write_text(json.dumps(record), encoding='utf-8')
        (resources / 'rillight-native-notices.md').write_text('notices')
        licenses = resources / 'rillight-native-licenses'
        licenses.mkdir()
        for name in NATIVE_LICENSES:
            (licenses / name).write_text('license')
        return app, record_path

    def test_verifies_owned_core_hash_and_rejects_mpv(self):
        with tempfile.TemporaryDirectory() as temp:
            app, record = self.make_app(Path(temp))
            def tool_output(command, **_):
                if command[0] == 'lipo':
                    return 'x86_64 arm64'
                return 'cmd LC_BUILD_VERSION\n  minos 12.0\n' \
                       'path @executable_path/../Frameworks (offset 12)\n'
            with patch('verify_bundle.subprocess.check_output', side_effect=tool_output), \
                 patch('verify_bundle.audit_binary'):
                self.assertEqual(verify(app)['target'], 'macos-universal')
                (app / 'Contents/Frameworks/libmpv.2.dylib').write_bytes(b'mpv')
                with self.assertRaisesRegex(RuntimeError, 'Legacy libmpv'):
                    verify(app)
                (app / 'Contents/Frameworks/libmpv.2.dylib').unlink()
                (app / 'Contents/Frameworks/librillight_core.dylib').write_bytes(b'changed')
                with self.assertRaisesRegex(RuntimeError, 'hash mismatch'):
                    verify(app)

    def test_rejects_dylib_requiring_newer_macos(self):
        with tempfile.TemporaryDirectory() as temp:
            app, _ = self.make_app(Path(temp))
            def tool_output(command, **_):
                if command[0] == 'lipo':
                    return 'x86_64 arm64'
                return 'cmd LC_BUILD_VERSION\n  minos 13.0\n'
            with patch('verify_bundle.subprocess.check_output', side_effect=tool_output), \
                 patch('verify_bundle.audit_binary'):
                with self.assertRaisesRegex(RuntimeError, 'exceeds macOS 12'):
                    verify(app)

    def test_final_signing_records_new_library_hashes_before_app_sign(self):
        with tempfile.TemporaryDirectory() as temp:
            app, record_path = self.make_app(Path(temp))
            commands = []
            expected = release_entitlements()
            def checked(command):
                commands.append(command)
            def output(command, **_):
                if '--verbose=4' in command:
                    return 'Executable=rillight\nSignature=adhoc\n'
                return plistlib.dumps(expected)
            with patch('sign_bundle.subprocess.check_call', side_effect=checked), \
                 patch('sign_bundle.subprocess.check_output', side_effect=output):
                sign(app)
            record = json.loads(record_path.read_text(encoding='utf-8'))
            self.assertEqual(record['final_libraries_sha256'], record['libraries'])
            self.assertEqual(commands[-2][-1], str(app.resolve()))
            self.assertIn('--entitlements', commands[-2])

    def test_signed_entitlements_are_checked_from_signature(self):
        expected = release_entitlements()
        actual = {**expected, 'com.apple.security.network.server': False}
        with patch('sign_bundle.subprocess.check_output',
                   return_value=plistlib.dumps(actual)):
            with self.assertRaisesRegex(ValueError, 'Signed entitlements differ'):
                verify_signed_entitlements('rillight.app', expected)


if __name__ == '__main__':
    unittest.main()
