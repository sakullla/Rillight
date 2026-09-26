"""Unit checks for the macOS universal SDK builder helpers."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build_macos_core_dependencies as macos
import prepare_macos
import verify_core_dependencies


class MacosBuilderHelpersTest(unittest.TestCase):
    def test_ffmpeg_flags_enable_owned_core_requirements(self):
        for flag in ("--enable-libdav1d", "--enable-videotoolbox",
                     "--enable-network", "--disable-autodetect",
                     "--disable-avdevice", "--enable-shared", "--disable-static"):
            self.assertIn(flag, macos.FFMPEG_CONFIGURE)
        self.assertNotIn("--enable-cross-compile", macos.FFMPEG_CONFIGURE)
        with patch.object(macos, "native_arch", return_value="arm64"):
            flags = macos.ffmpeg_configure(
                "x86_64", Path("/src/ffmpeg"), Path("/sdk"))
        self.assertIn("--enable-cross-compile", flags)
        self.assertIn("--arch=x86_64", flags)
        self.assertTrue(any("mmacosx-version-min=12.0" in item for item in flags))

    def test_abi_major_dylib_map_skips_unversioned_and_full_sonames(self):
        with tempfile.TemporaryDirectory() as temp:
            libdir = Path(temp)
            (libdir / "libavcodec.62.11.100.dylib").write_bytes(b"full")
            (libdir / "libavcodec.62.dylib").symlink_to("libavcodec.62.11.100.dylib")
            (libdir / "libavcodec.dylib").symlink_to("libavcodec.62.dylib")
            (libdir / "libdav1d.7.dylib").write_bytes(b"dav1d")
            mapping = macos.runtime_dylib_map(libdir)
            self.assertEqual(set(mapping), {"libavcodec.62.dylib", "libdav1d.7.dylib"})
            self.assertEqual(mapping["libavcodec.62.dylib"].read_bytes(), b"full")

    def test_meson_file_marks_foreign_arch_as_cross(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "x86_64.ini"
            macos.write_meson_file(
                path, "x86_64", cross=True, pkgdir=Path(temp) / "pkg",
                nasm=Path("/opt/homebrew/bin/nasm"),
                pkg_config=Path("/opt/homebrew/bin/pkg-config"))
            text = path.read_text(encoding="utf-8")
            self.assertIn("needs_exe_wrapper = true", text)
            self.assertIn("cpu_family = 'x86_64'", text)
            self.assertIn("-mmacosx-version-min=12.0", text)

    def test_builder_rejects_non_darwin_hosts(self):
        argv = ["build_macos_core_dependencies.py",
                "--prefix", "/tmp/macos-sdk", "--work", "/tmp/macos-work"]
        with patch.object(macos.platform, "system", return_value="Linux"), \
             patch.object(macos.sys, "argv", argv):
            with self.assertRaises(SystemExit):
                macos.main()

    def test_non_macho_bytes_are_not_sanitized(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "libavcodec.62.dylib"
            path.write_bytes(b"not-mach-o")
            self.assertFalse(prepare_macos.is_macho(path))

    def test_sanitize_rewrites_absolute_and_homebrew_paths(self):
        path = Path("/tmp/libavcodec.62.dylib")
        loads = [
            ["@rpath/libavcodec.62.dylib",
             "/opt/homebrew/lib/libavutil.60.dylib",
             "/usr/lib/libSystem.B.dylib"],
            ["@rpath/libavcodec.62.dylib",
             "@rpath/libavutil.60.dylib",
             "/usr/lib/libSystem.B.dylib"],
        ]
        rpaths = [
            ["/Users/builder/sdk/lib", "@loader_path"],
            ["@loader_path"],
            ["@loader_path"],
        ]
        commands = []
        with patch.object(prepare_macos, "load_dylibs", side_effect=loads), \
             patch.object(prepare_macos, "mach_o_rpaths", side_effect=rpaths), \
             patch.object(prepare_macos.subprocess, "check_call",
                          side_effect=lambda args: commands.append(args)):
            prepare_macos.sanitize_install_names(
                path, {"libavcodec.62.dylib", "libavutil.60.dylib"})
        self.assertIn(
            ["install_name_tool", "-id", "@rpath/libavcodec.62.dylib", str(path)],
            commands)
        self.assertIn(
            ["install_name_tool", "-change",
             "/opt/homebrew/lib/libavutil.60.dylib",
             "@rpath/libavutil.60.dylib", str(path)],
            commands)
        self.assertIn(
            ["install_name_tool", "-delete_rpath", "/Users/builder/sdk/lib",
             str(path)],
            commands)

    def test_verify_requires_videotoolbox_network_and_coretext(self):
        with tempfile.TemporaryDirectory() as temp:
            prefix = Path(temp)
            (prefix / "include/libavformat").mkdir(parents=True)
            marker = {
                "platform": "macos-universal",
                "ffmpeg_version": verify_core_dependencies.SPEC["ffmpeg"]["version"],
                "ffmpeg_commit": verify_core_dependencies.SPEC["ffmpeg"]["commit"],
                "ffmpeg_tag": verify_core_dependencies.SPEC["ffmpeg"]["version"],
                "ffmpeg_patches": verify_core_dependencies.SPEC["ffmpeg"]["patches"],
                "configure": ["--enable-libdav1d"],
                "libraries": {},
                "dav1d": {"version": "wrong"},
                "libass": {
                    "version": verify_core_dependencies.SPEC["libass"]["version"],
                    "commit": verify_core_dependencies.SPEC["libass"]["commit"],
                    "library": "lib/libass.9.dylib",
                    "sha256": "0" * 64,
                    "build_dependencies": {},
                },
            }
            (prefix / "rillight-core-dependencies.json").write_text(
                json.dumps(marker), encoding="utf-8")
            errors = verify_core_dependencies.verify(
                prefix, "macos-universal", require_subtitles=True)
            joined = "\n".join(errors)
            self.assertIn("VideoToolbox", joined)
            self.assertIn("network input is disabled", joined)
            self.assertIn("autodetection", joined)
            self.assertIn("font provider", joined)
            self.assertIn("subtitle source pins", joined)


if __name__ == "__main__":
    unittest.main()
