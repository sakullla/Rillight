"""Regression checks for the candidate-bound release evidence gate."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import player_core_release_checks as checks


REVISION = "a" * 40


class ReleaseEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "candidate.apk").write_bytes(b"candidate")
        (self.root / "libcore.so").write_bytes(b"core")
        (self.root / "run.log").write_text("observed output", encoding="utf-8")
        self.record = {
            "schema": 1,
            "target": "android-tv",
            "candidate_revision": REVISION,
            "artifact": "candidate.apk",
            "artifact_sha256": hashlib.sha256(b"candidate").hexdigest(),
            "dependencies": {
                "librillight_core": {
                    "path": "libcore.so",
                    "sha256": hashlib.sha256(b"core").hexdigest(),
                },
            },
            "checks": {
                name: {"passed": True, "evidence": "run.log",
                       "environment": "hardware"}
                for name in checks.REQUIRED
            },
        }

    def write_record(self):
        (self.root / "android-tv.json").write_text(
            json.dumps(self.record), encoding="utf-8")

    def test_verified_candidate_requires_matching_artifact_and_evidence(self):
        self.write_record()
        self.assertEqual(checks.audit_target("android-tv", self.root, REVISION, True), [])
        (self.root / "candidate.apk").write_bytes(b"different")
        self.assertIn("android-tv: candidate artifact SHA256 mismatch",
                      checks.audit_target("android-tv", self.root, REVISION, True))
        self.record["checks"]["actual_video"]["evidence"] = "missing.png"
        self.write_record()
        self.assertIn("android-tv: actual_video has no readable evidence",
                      checks.audit_target("android-tv", self.root, REVISION, True))

    def test_emulator_cannot_satisfy_hardware_requirement(self):
        self.record["checks"]["actual_audio"]["environment"] = "emulator"
        self.write_record()
        self.assertIn("android-tv: actual_audio lacks hardware evidence",
                      checks.audit_target("android-tv", self.root, REVISION, True))

    def test_explicit_mac_handoff_stays_unverified(self):
        handoff = self.root / "mac-handoff.md"
        handoff.write_text("pending target Mac playback", encoding="utf-8")
        # The absence of a Mac result is accepted only with an existing handoff.
        self.assertEqual(checks.main([
            "--target", "macos", "--candidate-revision", REVISION,
            "--evidence-root", str(self.root), "--require-hardware",
            "--macos-handoff", str(handoff),
        ]), 0)
        self.assertEqual(checks.main([
            "--target", "macos", "--candidate-revision", REVISION,
            "--evidence-root", str(self.root), "--require-hardware",
        ]), 1)
        (self.root / "macos.json").write_text("{}", encoding="utf-8")
        self.assertEqual(checks.main([
            "--target", "macos", "--candidate-revision", REVISION,
            "--evidence-root", str(self.root), "--require-hardware",
            "--macos-handoff", str(handoff),
        ]), 1)


if __name__ == "__main__":
    unittest.main()
