"""Regression checks for source locking in the Linux dependency builder."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from build_core_dependencies import fetch_source


def git(*args, cwd=None):
    return subprocess.check_output(
        ["git", *args], cwd=cwd, text=True, stderr=subprocess.DEVNULL
    ).strip()


class SourceLockTest(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
