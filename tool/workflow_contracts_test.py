"""Exercise macOS provisioning control flow with lightweight native-tool stubs."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / '.github/scripts/macos_core.sh'


class MacosProvisioningTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.write('packages/rillight_player/native/build_macos.sh', '''
test "${FAIL_SDK:-0}" != 1 || exit 7
mkdir -p "$1/lib"
echo '{}' > "$1/rillight-core-dependencies.json"
echo sdk > "$1/lib/test.dylib"
''')
        self.write('bin/cmake', '''
test "${FAIL_CORE:-0}" != 1 || exit 8
if [ "$1" = --build ]; then
  mkdir -p build/macos-core
  echo core > build/macos-core/librillight_core.dylib
fi
''')
        self.write('bin/python3', 'echo "$*" >> verified-commands.txt\n')
        self.write('bin/shasum', 'shift 2\nsha256sum "$@"\n')
        self.write('bin/git', "echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n")
        self.write('bin/xcodebuild', "echo 'Xcode test'\n")
        self.write('bin/xcrun', "echo 'macOS SDK test'\n")

    def write(self, name, script):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/usr/bin/env bash\nset -eu\n' + script,
                        encoding='utf-8', newline='\n')
        path.chmod(0o755)

    def provision(self, ref, **extra):
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(('CORE_SDK_', 'CORE_DYLIB_', 'ALLOW_SOURCE_BUILD'))}
        environment.update(GITHUB_REF=ref, **extra)
        bash = shutil.which('bash')
        git_bash = Path('C:/Program Files/Git/bin/bash.exe')
        if os.name == 'nt' and git_bash.is_file():
            bash = str(git_bash)
        return subprocess.run([
            bash, '-c', 'export PATH="$PWD/bin:$PATH" RUNNER_TEMP="$PWD/runner" '
            'GITHUB_ENV="$PWD/environment"; bash "$1"', 'workflow-test', SCRIPT.as_posix(),
        ], cwd=self.root, env=environment, text=True, capture_output=True, timeout=20)

    def test_ci_and_release_build_without_repository_artifact_variables(self):
        for ref in ('refs/heads/main', 'refs/pull/123/merge', 'refs/tags/v1.2.3'):
            with self.subTest(ref=ref):
                result = self.provision(ref)
                self.assertEqual(result.returncode, 0, result.stderr)
                evidence = self.root / 'build/macos-native-inputs'
                for line in (evidence / 'SHA256SUMS').read_text().splitlines():
                    checksum, name = line.split()
                    self.assertEqual(checksum, hashlib.sha256(
                        (evidence / name.lstrip('*')).read_bytes()).hexdigest())
                self.assertIn('RILLIGHT_MACOS_CORE_SHA256=',
                              (self.root / 'environment').read_text())
                self.assertIn('--target macos-universal --require-subtitles',
                              (self.root / 'verified-commands.txt').read_text())

    def test_failed_sdk_build_does_not_publish_a_core(self):
        result = self.provision('refs/tags/v1.2.3', FAIL_SDK='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'environment').exists())
        self.assertFalse((self.root / 'build/macos-core/librillight_core.dylib').exists())

    def test_failed_candidate_core_build_does_not_publish_environment(self):
        result = self.provision('refs/tags/v1.2.3', FAIL_CORE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'environment').exists())


if __name__ == '__main__':
    unittest.main()
