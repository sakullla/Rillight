"""Portable checks for macOS window-color sampling."""
import hashlib
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'macos'))
sys.path.insert(0, str(ROOT / 'tool'))
import capture_playback
import player_fixtures


class CapturePlaybackTest(unittest.TestCase):
    def test_colored_fraction_rejects_near_gray_and_accepts_testsrc(self):
        gray = Image.new('RGB', (640, 360), (40, 40, 40))
        fraction, digest = capture_playback.colored_fraction(gray)
        self.assertLess(fraction, 0.05)
        self.assertEqual(len(digest), 64)

        color = Image.new('RGB', (640, 360), (20, 20, 20))
        for x in range(120, 520):
            for y in range(80, 260):
                color.putpixel((x, y), (220, 30, 30))
        fraction, digest = capture_playback.colored_fraction(color)
        self.assertGreaterEqual(fraction, 0.05)
        self.assertNotEqual(digest, hashlib.sha256(b'').hexdigest())

    def test_player_pid_reads_child_production_main(self):
        pid = capture_playback.player_pid([
            {'event': 'production-main', 'value': {'pid': 1, 'player': False}},
            {'event': 'production-main', 'value': {'pid': 22, 'player': True}},
        ])
        self.assertEqual(pid, 22)

    def test_av1_encoder_prefers_libaom_then_svt(self):
        with patch('player_fixtures.subprocess.check_output',
                   return_value=' V..... libsvtav1\n V..... libaom-av1\n'):
            codec, extra = player_fixtures.av1_encoder('ffmpeg')
        self.assertEqual(codec, 'libaom-av1')
        self.assertIn('-cpu-used', extra)
        with patch('player_fixtures.subprocess.check_output',
                   return_value=' V..... libsvtav1\n'):
            codec, extra = player_fixtures.av1_encoder('ffmpeg')
        self.assertEqual(codec, 'libsvtav1')


if __name__ == '__main__':
    unittest.main()
