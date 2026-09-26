"""Exercise macOS CI input selection without downloading or building an SDK."""

import itertools
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / '.github/scripts/macos_core.sh'
INPUTS = {
    'CORE_SDK_URL': 'https://example.invalid/sdk.tar.gz',
    'CORE_SDK_SHA256': 'a' * 64,
    'CORE_DYLIB_URL': 'https://example.invalid/librillight_core.dylib',
    'CORE_DYLIB_SHA256': 'B' * 64,
}


class MacosInputSelectionTest(unittest.TestCase):
    def select(self, inputs=None, *, allow_source=True, ref='refs/heads/main'):
        environment = {key: value for key, value in os.environ.items()
                       if key not in INPUTS}
        environment.update(inputs or {})
        environment.update(ALLOW_SOURCE_BUILD=str(allow_source).lower(),
                           GITHUB_REF=ref)
        bash = shutil.which('bash')
        if os.name == 'nt':
            git_bash = Path('C:/Program Files/Git/bin/bash.exe')
            if git_bash.is_file():
                bash = str(git_bash)
        self.assertIsNotNone(bash, 'Bash is required for workflow regression checks')
        return subprocess.run([bash, SCRIPT.as_posix(), 'mode'],
                              env=environment, text=True, capture_output=True,
                              timeout=15)

    def test_ci_without_artifact_inputs_builds_from_pinned_source(self):
        for ref in ('refs/heads/main', 'refs/pull/123/merge'):
            with self.subTest(ref=ref):
                result = self.select(ref=ref)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), 'source')

    def test_source_build_requires_opt_in(self):
        result = self.select(allow_source=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing pinned macOS core inputs', result.stderr)

    def test_tags_cannot_fall_back_even_with_source_opt_in(self):
        result = self.select(ref='refs/tags/v1.2.3')
        self.assertNotEqual(result.returncode, 0)

    def test_complete_prebuilt_inputs_work_in_ci_and_release(self):
        for ref in ('refs/heads/main', 'refs/tags/v1.2.3'):
            with self.subTest(ref=ref):
                result = self.select(INPUTS, allow_source=False, ref=ref)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), 'prebuilt')

    def test_every_partial_configuration_fails_instead_of_falling_back(self):
        for size in range(1, len(INPUTS)):
            for keys in itertools.combinations(INPUTS, size):
                with self.subTest(keys=keys):
                    result = self.select({key: INPUTS[key] for key in keys})
                    self.assertNotEqual(result.returncode, 0)
                    for missing in INPUTS.keys() - set(keys):
                        self.assertIn(missing, result.stderr)

    def test_malformed_hash_is_rejected_before_network_access(self):
        for key in ('CORE_SDK_SHA256', 'CORE_DYLIB_SHA256'):
            for digest in ('short', 'z' * 64, 'a' * 64 + '\nextra'):
                with self.subTest(key=key, digest=digest):
                    result = self.select({**INPUTS, key: digest})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(key, result.stderr)


if __name__ == '__main__':
    unittest.main()
