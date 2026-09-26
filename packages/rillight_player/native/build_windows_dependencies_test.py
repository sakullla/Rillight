"""Check Windows DLL closure and generated manifest hashes without MSYS2."""

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from build_windows_dependencies import copy_runtime_dependencies, record_libraries
from verify_core_dependencies import digest


class WindowsSdkTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.prefix = self.root / 'sdk'
        self.mingw = self.root / 'mingw'
        for directory in (self.prefix / 'bin', self.prefix / 'lib',
                          self.mingw / 'bin', self.root / 'Windows/System32'):
            directory.mkdir(parents=True)
        self.environment = patch.dict(os.environ, {'SystemRoot': str(self.root / 'Windows')})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_transitive_dlls_are_copied_but_system_dlls_are_not(self):
        (self.prefix / 'bin/core.dll').write_bytes(b'core')
        (self.mingw / 'bin/direct.dll').write_bytes(b'direct')
        (self.mingw / 'bin/indirect.dll').write_bytes(b'indirect')
        (self.root / 'Windows/System32/KERNEL32.dll').write_bytes(b'system')
        imports = {'core.dll': 'DLL Name: direct.dll\nDLL Name: KERNEL32.dll',
                   'direct.dll': 'DLL Name: indirect.dll',
                   'indirect.dll': 'DLL Name: direct.dll\nDLL Name: api-ms-win-core-test.dll'}
        with patch('build_windows_dependencies.subprocess.check_output',
                   side_effect=lambda command, **_: imports[Path(command[-1]).name]):
            copy_runtime_dependencies(self.prefix, self.mingw)
        self.assertEqual({p.name for p in (self.prefix / 'bin').iterdir()},
                         {'core.dll', 'direct.dll', 'indirect.dll'})

    def test_unresolved_runtime_import_fails(self):
        (self.prefix / 'bin/core.dll').write_bytes(b'core')
        with patch('build_windows_dependencies.subprocess.check_output',
                   return_value='DLL Name: missing.dll'):
            with self.assertRaisesRegex(RuntimeError, 'missing.dll'):
                copy_runtime_dependencies(self.prefix, self.mingw)

    def test_rebuilt_core_gets_a_new_manifest_hash(self):
        core = self.prefix / 'bin/librillight_core.dll'
        core.write_bytes(b'old')
        marker = {'platform': 'windows-x64'}
        record_libraries(self.prefix, marker)
        old_hash = marker['libraries']['bin/librillight_core.dll']
        core.write_bytes(b'candidate')
        record_libraries(self.prefix, marker)
        saved = json.loads((self.prefix / 'rillight-core-dependencies.json').read_text())
        self.assertNotEqual(old_hash, saved['libraries']['bin/librillight_core.dll'])
        self.assertEqual(digest(core), saved['libraries']['bin/librillight_core.dll'])


if __name__ == '__main__':
    unittest.main()
