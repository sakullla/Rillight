"""Regression checks for source locking in the Linux dependency builder."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from build_core_dependencies import (
    SPEC, fetch_source, locked_ffmpeg_patches, require_pinned_file,
    stage_core_enhancement, verify_enhancement_models)
from build_android_core_dependencies import verify_supplied_source


def git(*args, cwd=None):
    return subprocess.check_output(
        ["git", *args], cwd=cwd, text=True, stderr=subprocess.DEVNULL
    ).strip()


class SourceLockTest(unittest.TestCase):
    def test_android_surface_patch_is_locked_and_excluded_from_desktop(self):
        desktop = locked_ffmpeg_patches()
        android = locked_ffmpeg_patches("android")
        self.assertNotIn("patches/ffmpeg-android-dolby-surface.patch", desktop)
        self.assertIn("patches/ffmpeg-android-dolby-surface.patch", android)
        self.assertNotIn("patches/ffmpeg-android-dovi-rpu.patch", desktop)
        self.assertIn("patches/ffmpeg-android-dovi-rpu.patch", android)
        self.assertTrue(set(desktop) < set(android))

    def test_android_patch_union_rejects_extra_edits_and_preserves_index(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            git("init", str(source))
            git("config", "core.autocrlf", "false", cwd=source)
            git("config", "user.name", "Test", cwd=source)
            git("config", "user.email", "test@example.invalid", cwd=source)
            for name in ("a.c", "b.c"):
                (source / name).write_text("original\n", encoding="utf-8")
            git("add", ".", cwd=source)
            git("commit", "-m", "locked", cwd=source)
            commit = git("rev-parse", "HEAD", cwd=source)
            patches = {}
            for name in ("a.c", "b.c"):
                (source / name).write_text("patched\n", encoding="utf-8")
                patch_file = root / (name + ".patch")
                patch_file.write_bytes(subprocess.check_output(
                    ["git", "-c", "core.abbrev=7", "diff", "--binary", "HEAD", "--", name], cwd=source))
                patches[name] = patch_file
            index = (source / ".git/index").read_bytes()
            with patch("build_android_core_dependencies.SPEC", {"ffmpeg": {"commit": commit}}), \
                    patch("build_android_core_dependencies.locked_ffmpeg_patches", return_value=patches):
                verify_supplied_source(source)
                self.assertEqual((source / ".git/index").read_bytes(), index)
                (source / "a.c").write_text("unexpected\n", encoding="utf-8")
                with self.assertRaisesRegex(RuntimeError, "differs from the locked patch"):
                    verify_supplied_source(source)

    def test_rewritten_fetch_url_keeps_locked_origin_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            upstream = root / "upstream"
            git("init", str(upstream))
            git("config", "user.name", "Test", cwd=upstream)
            git("config", "user.email", "test@example.invalid", cwd=upstream)
            (upstream / "source.txt").write_text("pinned", encoding="utf-8")
            git("add", "source.txt", cwd=upstream)
            git("commit", "-m", "pinned source", cwd=upstream)
            commit = git("rev-parse", "HEAD", cwd=upstream)
            git("tag", "v1", cwd=upstream)

            mirror = root / "mirror.git"
            git("clone", "--bare", str(upstream), str(mirror))
            locked_url = "https://locked.example.invalid/source.git"
            config = root / "gitconfig"
            config.write_text(
                f'[url "{mirror.as_uri()}"]\n'
                f"\tinsteadOf = {locked_url}\n",
                encoding="utf-8",
            )
            with patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": str(config)}):
                source = root / "checkout"
                fetch_source(source, locked_url, commit, "v1")
                self.assertEqual(
                    git("config", "--local", "--get", "remote.origin.url", cwd=source),
                    locked_url,
                )
                self.assertEqual(git("remote", "get-url", "origin", cwd=source), mirror.as_uri())
                self.assertEqual(git("rev-parse", "HEAD", cwd=source), commit)


class EnhancementPinTest(unittest.TestCase):
    def test_missing_pinned_file_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "missing.bin"
            with self.assertRaisesRegex(RuntimeError, "Missing enhancement file"):
                require_pinned_file(path, {"sha256": "ab", "bytes": 1}, "missing.bin")

    def test_hash_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "model.bin"
            path.write_bytes(b"nope")
            with self.assertRaisesRegex(RuntimeError, "pin mismatch"):
                require_pinned_file(
                    path, {"sha256": "0" * 64, "bytes": 4}, "model.bin")

    def test_model_tree_mismatch_fails_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            records = {}
            records.update(SPEC["enhancement"]["rife"]["files"])
            records.update(SPEC["enhancement"]["realesrgan"]["ncnn_weights"]["files"])
            self.assertEqual(len(records), 4)
            for relative, record in records.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"x" * record["bytes"])
            with self.assertRaisesRegex(RuntimeError, "pin mismatch"):
                verify_enhancement_models(root)

    def test_stage_removes_stale_weights_when_the_core_has_none(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "core"
            destination = root / "lib"
            source.mkdir()
            stale = destination / "rife-v4.6"
            stale.mkdir(parents=True)
            (stale / "flownet.bin").write_bytes(b"old")
            (destination / "realesr-general-x4v3.bin").write_bytes(b"old")
            (destination / "shaders").mkdir()
            self.assertFalse(stage_core_enhancement(source, destination))
            self.assertFalse(stale.exists())
            self.assertFalse((destination / "realesr-general-x4v3.bin").exists())
            self.assertFalse((destination / "shaders").exists())

    def test_stage_rejects_weights_that_miss_the_pin(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "core"
            (source / "rife-v4.6").mkdir(parents=True)
            (source / "rife-v4.6" / "flownet.bin").write_bytes(b"nope")
            with self.assertRaisesRegex(RuntimeError, "Missing enhancement file"):
                stage_core_enhancement(source, root / "lib")

    def test_stage_refuses_to_write_inside_the_source_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "core"
            source.mkdir()
            with self.assertRaisesRegex(RuntimeError, "outside the source tree"):
                stage_core_enhancement(source, source)


if __name__ == "__main__":
    unittest.main()
