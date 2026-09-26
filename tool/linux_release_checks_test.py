"""Portable regression tests for the Linux ELF/installer contracts."""
import json
import hashlib
from pathlib import Path
import shutil
import struct
import tempfile
import os
import subprocess
import unittest
from unittest.mock import patch

import linux_release_checks as checks


def write_elf(path, needed=(), soname=None, runpath='$ORIGIN', rpath=None):
    """Small valid ELF64 with program headers and no section table."""
    strings = bytearray(b'\0')
    entries = []
    for tag, names in [(1, needed), (14, [soname] if soname else []),
                       (29, [runpath] if runpath else []), (15, [rpath] if rpath else [])]:
        for name in names:
            entries.append((tag, len(strings)))
            strings.extend(name.encode() + b'\0')
    address, dynamic_offset, string_offset = 0x400000, 0x1000, 0x1400
    entries = [(5, address + string_offset), (10, len(strings)), *entries, (0, 0)]
    dynamic = b''.join(struct.pack('<qQ', *entry) for entry in entries)
    data = bytearray(string_offset + len(strings))
    identity = b'\x7fELF\x02\x01\x01' + bytes(9)
    data[:64] = struct.pack('<16sHHIQQQIHHHHHH', identity, 3, 62, 1, 0, 64, 0,
                            0, 64, 56, 2, 0, 0, 0)
    data[64:120] = struct.pack('<IIQQQQQQ', 1, 6, 0, address, address, len(data), len(data), 0x1000)
    data[120:176] = struct.pack('<IIQQQQQQ', 2, 6, dynamic_offset,
                              address + dynamic_offset, address + dynamic_offset,
                              len(dynamic), len(dynamic), 8)
    data[dynamic_offset:dynamic_offset + len(dynamic)] = dynamic
    data[string_offset:] = strings
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


class LinuxReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rillight-elf-test-')
        self.addCleanup(self.temp.cleanup)
        self.bundle = Path(self.temp.name)
        self.plugin = self.bundle / 'lib/librillight_player_plugin.so'
        self.core = self.bundle / 'lib/librillight_core.so'
        write_elf(self.bundle / 'rillight', ['librillight_player_plugin.so', 'libc.so.6'], runpath='$ORIGIN/lib')
        write_elf(self.plugin, ['librillight_core.so', 'libc.so.6'], 'librillight_player_plugin.so')
        write_elf(self.core, ['libavcodec.so.63', 'libc.so.6'], 'librillight_core.so')
        write_elf(self.bundle / 'lib/libavcodec.so.63', ['libc.so.6'], 'libavcodec.so.63')
        wrapper = self.bundle / 'rillight-launch'
        shutil.copyfile(checks.ROOT / 'linux/packaging/rillight-launch', wrapper)
        wrapper.chmod(0o755)
        notices = self.bundle / 'data/rillight_player'
        notices.mkdir(parents=True)
        spec = json.loads((checks.ROOT / 'packages/rillight_player/native/core_dependencies.json').read_text())
        (notices / 'rillight-core-dependencies.json').write_text(json.dumps({
            'platform': 'linux-x64', 'ffmpeg_version': spec['ffmpeg']['version'],
            'ffmpeg_commit': spec['ffmpeg']['commit'],
            'ffmpeg_patches': spec['ffmpeg']['patches'],
            'libass': {'commit': spec['libass']['commit']},
            'dav1d': {'commit': spec['dav1d']['commit']},
        }))
        self.write_report()

    def write_report(self):
        notices = self.bundle / 'data/rillight_player'
        (notices / 'loaded-versions.json').write_text(json.dumps({
            'coreAbi': 8, 'versions': 'ffmpeg=9.0.1;avformat=1',
            'bundledLibraries': {
                str(path.relative_to(self.bundle)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (self.bundle / 'lib').glob('*.so*') if path.is_file() and not path.is_symlink()
            },
        }))

    def test_valid_bundle_reads_real_program_headers_without_sections(self):
        files = checks.verify_bundle(self.bundle, runtime=False,
                                     desktop=checks.ROOT / 'linux/packaging/rillight.desktop')
        self.assertEqual(len(files), 4)
        self.assertEqual(files[self.plugin]['needed'], ['librillight_core.so', 'libc.so.6'])

    def test_loaded_ffmpeg_version_accepts_pinned_tag_spelling_only(self):
        class Function:
            def __init__(self, value):
                self.value = value

            def __call__(self):
                return self.value

        class Core:
            rillight_core_abi_version = Function(8)
            rillight_core_ffmpeg_versions = Function(b'ffmpeg=n9.0.1;avformat=1')

        with patch.object(checks.ctypes, 'CDLL', return_value=Core()):
            self.assertEqual(checks.loaded_core_versions(self.bundle)['coreAbi'], 8)
            Core.rillight_core_ffmpeg_versions.value = b'ffmpeg=9.0.1;avformat=1'
            self.assertEqual(checks.loaded_core_versions(self.bundle)['coreAbi'], 8)
            Core.rillight_core_ffmpeg_versions.value = b'ffmpeg=n9.0.2;avformat=1'
            with self.assertRaisesRegex(ValueError, 'version mismatch'):
                checks.loaded_core_versions(self.bundle)

    def test_legacy_plugin_is_rejected_even_when_new_core_is_present(self):
        write_elf(self.bundle / 'lib/libold_plugin.so', ['libmpv.so.1'], runpath='$ORIGIN')
        with self.assertRaisesRegex(ValueError, 'libmpv'):
            checks.verify_bundle(self.bundle, runtime=False)

    def test_legacy_alias_is_never_an_abi_fix(self):
        shutil.copyfile(self.core, self.bundle / 'lib/libmpv.so.2')
        with self.assertRaisesRegex(ValueError, 'libmpv'):
            checks.verify_bundle(self.bundle, runtime=False)

    def test_renamed_library_must_retain_the_correct_soname(self):
        write_elf(self.core, ['libc.so.6'], 'libmpv.so.2')
        with self.assertRaisesRegex(ValueError, 'SONAME'):
            checks.verify_bundle(self.bundle, runtime=False)

    def test_plugin_build_machine_runpath_is_rejected(self):
        write_elf(self.plugin, ['librillight_core.so'], 'librillight_player_plugin.so',
                  runpath='/home/runner/work/Rillight/linux/flutter/ephemeral')
        with self.assertRaisesRegex(ValueError, 'RUNPATH'):
            checks.verify_bundle(self.bundle, runtime=False)

    def test_transitive_media_library_needs_its_own_runpath(self):
        write_elf(self.core, ['libavcodec.so.63'], 'librillight_core.so', runpath=None)
        with self.assertRaisesRegex(ValueError, 'RUNPATH'):
            checks.verify_bundle(self.bundle, runtime=False)

    def test_missing_transitive_media_library_is_not_a_system_fallback(self):
        (self.bundle / 'lib/libavcodec.so.63').unlink()
        with self.assertRaisesRegex(ValueError, 'unbundled media dependency'):
            checks.verify_bundle(self.bundle, runtime=False)

    def test_changed_core_bytes_fail_final_bundle_hash(self):
        with self.core.open('ab') as output:
            output.write(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'SHA256 mismatch'):
            checks.verify_bundle(self.bundle, runtime=False)

    def test_unbundled_libass_is_rejected(self):
        write_elf(self.core, ['libass.so.9'], 'librillight_core.so')
        with self.assertRaisesRegex(ValueError, 'unbundled media dependency'):
            checks.verify_bundle(self.bundle, runtime=False)

    def test_system_core_resolution_is_rejected(self):
        resolved = {path.name: str(path) for path in self.bundle.rglob('*.so*')}
        resolved.update({'librillight_core.so': '/usr/lib/librillight_core.so', 'libc.so.6': '/lib/libc.so.6'})
        with patch.object(checks, 'run', return_value='unused'), \
                patch.object(checks, 'parse_ldd', return_value=resolved):
            with self.assertRaisesRegex(ValueError, 'outside the bundle'):
                checks.verify_bundle(self.bundle, integrity=False)

    def test_missing_library_diagnostic_and_runtime_mapping(self):
        with self.assertRaisesRegex(ValueError, 'Unresolved'):
            checks.parse_ldd('librillight_core.so => not found\n')
        self.assertEqual(checks.parse_ldd(' librillight_core.so => /opt/rillight/lib/librillight_core.so (0x123)\n'),
                         {'librillight_core.so': '/opt/rillight/lib/librillight_core.so'})

    def test_unresolved_runtime_dependency_names_the_file(self):
        with patch.object(checks, 'run', return_value='libjvm.so => not found\n'):
            with self.assertRaises(ValueError) as raised:
                checks.verify_bundle(self.bundle, integrity=False)
        message = str(raised.exception)
        self.assertIn('Unresolved ELF dependency', message)
        self.assertRegex(message, r'^\S+: Unresolved')

    def test_jvm_helper_is_not_a_desktop_runtime_dependency(self):
        write_elf(self.bundle / 'lib/libdartjni.so', ['libjvm.so', 'libc.so.6'], 'libdartjni.so')
        with self.assertRaisesRegex(ValueError, r'libdartjni\.so: desktop bundle must not link a JVM'):
            checks.verify_bundle(self.bundle, runtime=False)

    def test_desktop_plugin_list_does_not_register_android_jni(self):
        for name in ('linux/flutter/generated_plugins.cmake', 'windows/flutter/generated_plugins.cmake'):
            text = (checks.ROOT / name).read_text(encoding='utf-8')
            self.assertNotRegex(text, r'^\s*jni\s*$', msg=name)

    def test_desktop_cannot_bypass_wrapper(self):
        desktop = self.bundle / 'rillight.desktop'
        desktop.write_text('[Desktop Entry]\nExec=/opt/rillight/rillight\nTerminal=false\n')
        with self.assertRaisesRegex(ValueError, 'normal diagnostic wrapper'):
            checks.verify_entrypoints(self.bundle, desktop)

    def test_missing_wrapper_is_rejected(self):
        (self.bundle / 'rillight-launch').unlink()
        with self.assertRaisesRegex(ValueError, 'wrapper'):
            checks.verify_bundle(self.bundle, runtime=False)

    def test_build_prefix_cannot_be_replaced_with_arbitrary_system_pkgconfig(self):
        with self.assertRaisesRegex(ValueError, 'verified pinned FFmpeg core SDK'):
            checks.prepare_bundle(self.bundle / 'empty-prefix', self.bundle)

    def test_old_mpv_prefix_cannot_be_used(self):
        prefix = self.bundle / 'old-prefix'
        prefix.mkdir()
        (prefix / 'rillight-source-versions.txt').write_text('mpv=0.41.0\nffmpeg=n9.0.1\n')
        with self.assertRaisesRegex(ValueError, 'verified pinned FFmpeg core SDK'):
            checks.prepare_bundle(prefix, self.bundle)

    def test_dpkg_shlibdeps_maps_private_libraries_and_retains_real_system_depends(self):
        def shlibdeps(command, **kwargs):
            local = (Path(kwargs['cwd']) / 'debian/shlibs.local').read_text()
            self.assertIn('librillight_core 0 rillight', local)
            self.assertIn('libavcodec 63 rillight', local)
            self.assertIn('-xrillight', command)
            self.assertNotIn('--ignore-missing-info', command)
            return 'shlibs:Depends=libc6 (>= 2.34), libgtk-3-0 (>= 3.24)\n'
        with patch.object(checks, 'run', side_effect=shlibdeps):
            result = checks.package_dependencies(self.bundle, checks.elf_files(self.bundle))
        self.assertIn('libgtk-3-0', result)
        self.assertIn('zenity', result)
        self.assertIn('libc-bin', result)

    def test_runtime_checks_remove_loader_overrides(self):
        with patch.dict(checks.os.environ, {'LD_LIBRARY_PATH': '/old', 'LD_PRELOAD': '/bad.so', 'LC_ALL': 'zh_CN'}):
            environment = checks.clean_environment()
        self.assertNotIn('LD_LIBRARY_PATH', environment)
        self.assertNotIn('LD_PRELOAD', environment)
        self.assertEqual(environment['LC_ALL'], 'C')

    @unittest.skipIf(os.name == 'nt', 'POSIX shell execution; run this suite in WSL/Linux')
    def test_normal_launcher_forwards_arguments_and_drops_loader_override(self):
        self.launcher_case(missing_core=False)

    @unittest.skipIf(os.name == 'nt', 'POSIX shell execution; run this suite in WSL/Linux')
    def test_missing_core_is_logged_and_sent_to_visible_error_command(self):
        self.launcher_case(missing_core=True)

    @unittest.skipIf(os.name == 'nt', 'POSIX shell execution; run this suite in WSL/Linux')
    def test_missing_transitive_library_blocks_launch_and_reports_diagnostic(self):
        self.launcher_case(missing_core=False, missing_transitive=True)

    def launcher_case(self, missing_core, missing_transitive=False):
        tools = self.bundle / 'tools'
        tools.mkdir()
        executable = self.bundle / 'rillight'
        executable.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$RILLIGHT_LAUNCH_MARKER"\n')
        executable.chmod(0o755)
        ldd = tools / 'ldd'
        ldd.write_text('#!/bin/sh\n[ -z "${LD_LIBRARY_PATH:-}" ] || exit 8\n' + (
            'echo "libmissing.so.9 => not found"\n' if missing_transitive else 'exit 0\n'))
        ldd.chmod(0o755)
        zenity = tools / 'zenity'
        zenity.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$RILLIGHT_DIALOG_MARKER"\n')
        zenity.chmod(0o755)
        if missing_core:
            self.core.unlink()
        launched, dialog = self.bundle / 'launched', self.bundle / 'dialog'
        env = {**os.environ, 'PATH': str(tools) + os.pathsep + os.environ['PATH'],
               'XDG_STATE_HOME': str(self.bundle / 'state'), 'LD_LIBRARY_PATH': '/old-lib',
               'RILLIGHT_LAUNCH_MARKER': str(launched), 'RILLIGHT_DIALOG_MARKER': str(dialog)}
        result = subprocess.run([str(self.bundle / 'rillight-launch'), 'player', 'path with spaces'],
                                env=env, capture_output=True, text=True)
        if missing_core or missing_transitive:
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertFalse(launched.exists())
            self.assertIn('Rillight 启动失败', dialog.read_text())
            self.assertTrue((self.bundle / 'state/rillight/launch.log').is_file())
        else:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(launched.read_text().splitlines(), ['player', 'path with spaces'])
            self.assertFalse(dialog.exists())


if __name__ == '__main__':
    unittest.main()
