"""Portable regression for thin/fat otool output used by native packaging."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'packages/rillight_player/native'))
from bundle_macos import otool_dependencies


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


if __name__ == '__main__':
    unittest.main()
