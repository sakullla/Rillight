"""Checks for missing samples, failed runs and device-matched comparison."""

import json
import hashlib
from pathlib import Path
import tempfile
import unittest
from PIL import Image

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
        before = [self.row("baseline", kind, 30) for kind in performance.REQUIRED["android-tv"] for _ in range(20)]
        after = [self.row("candidate", kind, 10) for kind in performance.REQUIRED["android-tv"] for _ in range(20)]
        after[0]["complete"] = False
        baseline, before_errors = self.write("baseline", before)
        candidate, after_errors = self.write("candidate", after)
        self.assertEqual(before_errors + after_errors, [])
        _, errors = performance.compare(baseline, candidate, targets=("android-tv",))
        self.assertTrue(any("more failed" in error for error in errors))

    def test_matching_scenarios_with_20_runs_show_actual_gain(self):
        before = [self.row("baseline", kind, 30) for kind in performance.REQUIRED["android-tv"] for _ in range(20)]
        after = [self.row("candidate", kind, 10) for kind in performance.REQUIRED["android-tv"] for _ in range(20)]
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

    def test_android_phone_requires_visible_frame_image_and_physical_energy(self):
        rows = []
        for category in performance.REQUIRED["android-phone"]:
            row = self.row("candidate", category, 10, target="android-phone")
            if category == "image":
                row.update(firstRenderedImageMs=10, renderedImageObserved=False)
            if category == "startup":
                row.update(firstDisplayedFrameMs=10, nativeFirstFrameMs=5)
            if category in ("power", "thermal"):
                row.update(energyMWh=10, tempRiseC=1,
                           environment="emulator", measurementMethod="power-rail",
                           initialTempC=30, brightnessPercent=50, volumePercent=50)
            rows.append(row)
        groups, errors = self.write("candidate", rows)
        self.assertEqual(errors, [])
        by_category = {key[1]: values[0] for key, values in groups.items()}
        for category in ("image", "startup", "power", "thermal"):
            self.assertFalse(by_category[category]["complete"])

    def test_android_phone_complete_physical_pairs_cover_all_categories(self):
        before_screen = self.root / 'screen-before.png'
        screenshot = self.root / 'screen-after.png'
        Image.new('RGB', (100, 100), 'black').save(before_screen)
        Image.new('RGB', (100, 100), 'red').save(screenshot)
        rows = {'baseline': [], 'candidate': []}
        for phase, value in (('baseline', 30), ('candidate', 10)):
            for category in performance.REQUIRED['android-phone']:
                for _ in range(20):
                    row = self.row(phase, category, value, target='android-phone')
                    row.update(firstRenderedImageMs=value, firstDisplayedImageMs=value,
                               renderedImageObserved=True,
                               screenBeforePath=before_screen.name,
                               screenBeforeSha256=hashlib.sha256(
                                   before_screen.read_bytes()).hexdigest(),
                               screenRegion=[0, 0, 100, 100],
                               displayedImageEvidencePath=screenshot.name,
                               displayedImageEvidenceSha256=hashlib.sha256(
                                   screenshot.read_bytes()).hexdigest(),
                               displayedImageClockUncertaintyMs=5,
                               firstDisplayedFrameMs=value,
                               displayedFrameEvidencePath=screenshot.name,
                               displayedFrameEvidenceSha256=hashlib.sha256(
                                   screenshot.read_bytes()).hexdigest(),
                               displayedFrameClockUncertaintyMs=5,
                               screenPixelChangeObserved=True,
                               energyMWh=value, tempRiseC=value,
                               environment='physical', elapsedMs=300000,
                               measurementMethod='thermal-zone' if category == 'thermal'
                               else 'power-rail', initialTempC=30,
                               brightnessPercent=50, volumePercent=40)
                    rows[phase].append(row)
        baseline, before_errors = self.write('baseline', rows['baseline'])
        candidate, after_errors = self.write('candidate', rows['candidate'])
        self.assertEqual(before_errors + after_errors, [])
        comparisons, errors = performance.compare(
            baseline, candidate, targets=('android-phone',))
        self.assertEqual(errors, [])
        self.assertEqual(len(comparisons), len(performance.REQUIRED['android-phone']))
        self.assertTrue(all(row['verdict'] == 'improved' for row in comparisons))

    def test_unchanged_screen_pixels_do_not_prove_displayed_image(self):
        screenshot = self.root / 'unchanged.png'
        Image.new('RGB', (100, 100), 'black').save(screenshot)
        digest = hashlib.sha256(screenshot.read_bytes()).hexdigest()
        row = self.row('candidate', 'image', 10, target='android-phone',
                       renderedImageObserved=True, firstDisplayedImageMs=10,
                       screenPixelChangeObserved=True,
                       screenBeforePath=screenshot.name, screenBeforeSha256=digest,
                       displayedImageEvidencePath=screenshot.name,
                       displayedImageEvidenceSha256=digest,
                       displayedImageClockUncertaintyMs=5,
                       screenRegion=[0, 0, 100, 100])
        groups, errors = self.write('candidate', [row])
        self.assertEqual(errors, [])
        self.assertFalse(next(iter(groups.values()))[0]['complete'])


if __name__ == "__main__":
    unittest.main()
