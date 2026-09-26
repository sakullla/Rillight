"""Checks for missing samples, failed runs and device-matched comparison."""

import json
import hashlib
from pathlib import Path
import tempfile
import unittest

import player_performance_checks as performance


class PerformanceEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "baseline.bin").write_bytes(b"baseline artifact")
        (self.root / "candidate.bin").write_bytes(b"candidate artifact")

    def row(self, phase, category, value, **changes):
        row = {
            "phase": phase, "target": "android-tv", "category": category,
            "label": f"{category}/scene", "cache": "cold", "device": "tv-serial-1",
            "buildMode": "profile", "media": "sample-1080p", "network": "20mbps-50ms",
            "quality": "1080p", "frameBudgetMs": 16.67,
            "artifactPath": f"{phase}.bin",
            "artifactSha256": hashlib.sha256(
                f"{phase} artifact".encode()).hexdigest(),
            "complete": True, "firstOperableMs": value, "stallMs": value,
            "elapsedMs": 60000,
            "frameTimingsComplete": True,
            "uiFrameMs": [value], "rasterFrameMs": [value],
        }
        row.update(changes)
        return row

    def write(self, phase, rows):
        path = self.root / f"{phase}.jsonl"
        path.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
        return performance.load_rows(path, phase)

    def test_failure_samples_are_kept_and_block_regression(self):
        before = [self.row("baseline", kind, 30) for kind in performance.CATEGORIES for _ in range(20)]
        after = [self.row("candidate", kind, 10) for kind in performance.CATEGORIES for _ in range(20)]
        after[0]["complete"] = False
        baseline, before_errors = self.write("baseline", before)
        candidate, after_errors = self.write("candidate", after)
        self.assertEqual(before_errors + after_errors, [])
        _, errors = performance.compare(baseline, candidate, targets=("android-tv",))
        self.assertTrue(any("more failed" in error for error in errors))

    def test_matching_scenarios_with_20_runs_show_actual_gain(self):
        before = [self.row("baseline", kind, 30) for kind in performance.CATEGORIES for _ in range(20)]
        after = [self.row("candidate", kind, 10) for kind in performance.CATEGORIES for _ in range(20)]
        baseline, _ = self.write("baseline", before)
        candidate, _ = self.write("candidate", after)
        comparisons, errors = performance.compare(baseline, candidate, targets=("android-tv",))
        self.assertEqual(errors, [])
        self.assertEqual([row["verdict"] for row in comparisons], ["improved"] * 3)
        candidate[tuple(after[0][key] for key in performance.KEY)] = []
        _, missing_errors = performance.compare(baseline, candidate, targets=("android-tv",))
        self.assertTrue(any("requires 20" in error for error in missing_errors))

    def test_artifact_mismatch_and_short_animation_are_not_measurements(self):
        invalid = self.row("candidate", "animation", 10, elapsedMs=1000)
        groups, errors = self.write("candidate", [invalid])
        self.assertEqual(errors, [])
        sample = next(iter(groups.values()))[0]
        self.assertFalse(sample["complete"])
        (self.root / "candidate.bin").write_bytes(b"changed")
        groups, errors = self.write("candidate", [invalid])
        self.assertFalse(groups)
        self.assertTrue(any("hash mismatch" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
