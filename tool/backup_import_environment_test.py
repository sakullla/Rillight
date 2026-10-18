"""Compile the production key loader to AOT using synthetic defines only."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class EnvironmentKeysTest(unittest.TestCase):
    def test_aot_key_injection_and_secretless_build(self):
        dart = shutil.which('dart')
        self.assertIsNotNone(dart, 'Dart SDK must be on PATH')
        loader = (ROOT / 'lib/auth/backup_import/environment_keys.dart').as_uri()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            probe = root / 'probe.dart'
            probe.write_text(f"""
import 'dart:convert';
import '{loader}';
void main() {{
  final keys = defaultBackupImportKeys;
  print(jsonEncode([
    keys.hillsDataKey,
    keys.rodelCommonKeysBySource,
    keys.rodelBackupConfigKeys,
  ]));
}}
""", encoding='utf-8')
            binary = root / ('probe.exe' if os.name == 'nt' else 'probe')
            for injected in (False, True):
                with self.subTest(injected=injected):
                    defines = ([
                        '-DRILLIGHT_HILLS_KEY=' + 'ab' * 32,
                        '-DRILLIGHT_COMMON_KEY=' + 'cd' * 32,
                        '-DRILLIGHT_RPB_KEY=' + 'ef' * 16,
                    ] if injected else [])
                    result = subprocess.run(
                        [dart, 'compile', 'exe', *defines, str(probe), '-o', str(binary)],
                        capture_output=True, text=True, timeout=120,
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    result = subprocess.run([str(binary)], capture_output=True,
                                            text=True, check=True, timeout=10)
                    expected = ([[0xab] * 32, {'RodelPlayer': [0xcd] * 32},
                                 [[0xef] * 16]] if injected else [None, {}, []])
                    self.assertEqual(json.loads(result.stdout), expected)


if __name__ == '__main__':
    unittest.main()
