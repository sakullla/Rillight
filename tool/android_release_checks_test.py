"""Regression checks for evidence rejection and the real synthetic HTTP fixture."""
import array
from contextlib import ExitStack
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
import urllib.error
import urllib.request

from android_release_checks import Device, audio_metrics, pixel_check, playback_reports
import android_release_checks as checks


class EvidenceTests(unittest.TestCase):
    def test_matrix_rejects_missing_and_failed_reports_after_first_device_passes(self):
        # Execute the real main decision path. Only Android/process boundaries
        # and app/native observations are replaced; this is not device evidence.
        state = {'report_count': 0, 'reports': []}

        class FakeDevice(Device):
            def adb(self, *args, **kwargs):
                if args == ('shell', 'pm', 'list', 'features'):
                    return b'android.software.leanback' if self.serial == 'tv' else b''
                if args == ('shell', 'wm', 'size'):
                    return {'p360': b'360x800', 'p412': b'412x800', 'tv': b'960x540'}[self.serial]
                if args == ('shell', 'wm', 'density'):
                    return b'160'
                return b'36'

        def observe_app(device, tv):
            paths = ['/Sessions/Playing', '/Sessions/Playing/Stopped'] if device.serial == 'p360' else (
                ['/Sessions/Playing/Stopped'] if tv else [])
            for path in paths:
                state['report_count'] += 1
                state['reports'].append({'sequence': state['report_count'], 'path': path,
                                         'accepted': device.serial == 'p360'})
            return {'virtual_audio': {'passed': True}}

        with tempfile.TemporaryDirectory() as folder, ExitStack() as stack:
            root = Path(folder)
            (root / 'android-tracks.mkv').touch()
            output = root / 'result'

            def process(*args, **kwargs):
                fixture = output / 'fixture'
                fixture.mkdir(exist_ok=True)
                (fixture / 'server.json').write_text('{}')
                return Mock(poll=Mock(return_value=None))

            def external_run(args, **kwargs):
                if args[-1] == 'devices':
                    return b'List of devices attached\np360\tdevice\np412\tdevice\ntv\tdevice\n'
                return b'synthetic-head' if args[-1] == 'HEAD' else b''

            replacements = {'Device': FakeDevice, 'run': external_run, 'sdk_path': lambda: root,
                            'apk_check': lambda *a, **k: {}, 'fixture_state': lambda: state,
                            'app_flow': observe_app, 'native_flow': lambda *a: {}}
            stack.enter_context(patch.multiple(checks, **replacements))
            stack.enter_context(patch.object(checks.subprocess, 'Popen', side_effect=process))
            stack.enter_context(patch.object(checks.time, 'sleep'))
            stack.enter_context(patch('builtins.print'))
            stack.enter_context(patch.object(sys, 'argv', ['verify', '--all-targets', '--app-apk', 'a',
                '--native-apk', 'b', '--media', str(root), '--output', str(output)]))
            self.assertEqual(checks.main(), 1)
            result = json.loads((output / 'result.json').read_text(encoding='utf-8'))
            self.assertFalse(result['passed'])
            self.assertEqual([device['passed'] for device in result['devices']], [True, False, False])

    def test_hide_ime_does_not_send_back_without_visible_keyboard(self):
        device = Device('synthetic', Path('.'))
        device.adb = Mock(return_value=b'mInputShown=false')
        device.key = Mock()
        device.hide_ime()
        device.key.assert_not_called()
        device.adb.return_value = b'mInputShown=true'
        device.hide_ime()
        device.key.assert_called_once_with(4)

    def test_tap_waits_for_rotated_target_to_settle(self):
        with tempfile.TemporaryDirectory() as folder:
            device = Device('synthetic', Path(folder))
            landscape = ({'size': [800, 360], 'scale': 2}, {'rect': [20, 30, 60, 70]})
            portrait = ({'size': [360, 800], 'scale': 2}, {'rect': [100, 600, 140, 640]})
            device.row = Mock(side_effect=[landscape, portrait, portrait])
            device.adb = Mock()
            with patch('android_release_checks.time.sleep'):
                device.tap(key='synthetic-toggle')
            device.adb.assert_called_once_with('shell', 'input', 'tap', 240, 1240)

    def test_prior_device_reports_cannot_pass_current_device(self):
        state = {'report_count': 2, 'reports': [
            {'sequence': 1, 'path': '/Sessions/Playing', 'accepted': True},
            {'sequence': 2, 'path': '/Sessions/Playing/Stopped', 'accepted': True}]}
        self.assertTrue(playback_reports(state, 0)['passed'])
        self.assertFalse(playback_reports(state, 2)['passed'])
        state['reports'].append({'sequence': 3, 'path': '/Sessions/Playing/Stopped', 'accepted': False})
        state['report_count'] = 3
        self.assertFalse(playback_reports(state, 2)['passed'])

    def test_current_report_pair_survives_rolling_window(self):
        state = {'report_count': 102, 'reports': [
            {'sequence': 101, 'path': '/Sessions/Playing', 'accepted': True},
            {'sequence': 102, 'path': '/Sessions/Playing/Stopped', 'accepted': True}]}
        self.assertTrue(playback_reports(state, 100)['passed'])
        self.assertFalse(playback_reports(state, 101)['passed'])

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

    def test_reports_have_monotonic_sequence_across_rolling_window(self):
        with self.request('/__state') as response:
            start = json.load(response)['report_count']
        for _ in range(41):
            self.request('/Sessions/Playing/Stopped', {'ItemId': 'movie-01'}).close()
        with self.request('/__state') as response:
            state = json.load(response)
        self.assertEqual(state['report_count'], start + 41)
        self.assertEqual(len(state['reports']), 40)
        self.assertEqual(state['reports'][-1]['sequence'], start + 41)


if __name__ == '__main__':
    unittest.main()
