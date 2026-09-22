"""Regression checks for evidence rejection and the real synthetic HTTP fixture."""
import array
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

from android_release_checks import audio_metrics, pixel_check


class EvidenceTests(unittest.TestCase):
    def test_silence_fails(self):
        self.assertFalse(audio_metrics(bytes(48000 * 4 * 6), 48000, 6)['passed'])

    def test_short_loud_packet_fails(self):
        pcm = array.array('h', [1000, -1000] * 100).tobytes()
        self.assertFalse(audio_metrics(pcm, 48000, 6)['passed'])

    def test_complete_signal_passes(self):
        pcm = array.array('h', [1000, -1000] * (48000 * 6)).tobytes()
        self.assertTrue(audio_metrics(pcm, 48000, 6)['passed'])

    def test_static_color_and_moving_controls_fail(self):
        from PIL import Image, ImageDraw
        with tempfile.TemporaryDirectory() as folder:
            a, b = Path(folder) / 'a.png', Path(folder) / 'b.png'
            image = Image.new('RGB', (360, 800), 'red')
            image.save(a)
            ImageDraw.Draw(image).rectangle((0, 0, 100, 100), fill='white')
            image.save(b)
            with self.assertRaisesRegex(RuntimeError, 'No changing'):
                pixel_check(a, b)

    def test_grayscale_animation_fails(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as folder:
            a, b = Path(folder) / 'a.png', Path(folder) / 'b.png'
            Image.new('RGB', (360, 800), 'black').save(a)
            Image.new('RGB', (360, 800), 'white').save(b)
            with self.assertRaisesRegex(RuntimeError, 'No changing'):
                pixel_check(a, b)

    def test_landscape_motion_uses_video_above_center(self):
        from PIL import Image, ImageDraw
        with tempfile.TemporaryDirectory() as folder:
            a, b = Path(folder) / 'a.png', Path(folder) / 'b.png'
            image = Image.new('RGB', (960, 540), 'red')
            image.save(a)
            ImageDraw.Draw(image).rectangle((200, 150, 700, 210), fill='blue')
            image.save(b)
            self.assertGreater(pixel_check(a, b)['mean_rgb_difference'], 2)


class FixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.path = Path(cls.directory.name)
        (cls.path / 'bytes.mkv').write_bytes(bytes(range(100)))
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        cls.base = f'http://127.0.0.1:{port}'
        cls.process = subprocess.Popen([sys.executable, str(Path(__file__).with_name('android_fixtures.py')),
            '--port', str(port), '--media', str(cls.path), '--output', str(cls.path)], stdout=subprocess.DEVNULL)
        for _ in range(100):
            if (cls.path / 'server.json').exists():
                return
            if cls.process.poll() is not None:
                raise RuntimeError('Fixture exited')
            time.sleep(.05)
        raise RuntimeError('Fixture startup timed out')

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(timeout=5)
        cls.directory.cleanup()

    def request(self, path, body=None, headers=None):
        request = urllib.request.Request(self.base + path,
            data=None if body is None else json.dumps(body).encode(),
            headers=headers or {'X-Emby-Token': 'synthetic-mobile-token'})
        return urllib.request.urlopen(request, timeout=5)

    def tearDown(self):
        self.request('/__control', {'offline': False, 'expired': False, 'auth_fail': False, 'media_fail': False}).close()

    def test_authentication_requires_fixture_password(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request('/Users/AuthenticateByName', {'Username': 'mobile', 'Pw': 'wrong'})
        self.assertEqual(caught.exception.code, 401)
        caught.exception.close()
        with self.request('/Users/AuthenticateByName', {'Username': 'mobile', 'Pw': 'test-only'}) as response:
            self.assertEqual(json.load(response)['User']['Id'], 'mobile-user')

    def test_faults_are_observable(self):
        self.request('/__control', {'offline': True}).close()
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request('/Users/mobile-user/Views')
        self.assertEqual(caught.exception.code, 503)
        caught.exception.close()

    def test_media_ranges_and_traversal(self):
        headers = {'X-Emby-Token': 'synthetic-mobile-token', 'Range': 'bytes=10-19'}
        with self.request('/media/bytes.mkv', headers=headers) as response:
            self.assertEqual(response.status, 206)
            self.assertEqual(response.read(), bytes(range(10, 20)))
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request('/media/../outside.mkv')
        self.assertEqual(caught.exception.code, 404)
        caught.exception.close()

    def test_pagination_keeps_total(self):
        with self.request('/Users/mobile-user/Items?ParentId=movies&StartIndex=50&Limit=50') as response:
            result = json.load(response)
        self.assertEqual(result['TotalRecordCount'], 51)
        self.assertEqual(len(result['Items']), 1)


if __name__ == '__main__':
    unittest.main()
