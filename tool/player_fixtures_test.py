"""Verify loopback startup and the playback fixture's Emby API contract."""

from http.server import BaseHTTPRequestHandler
import json
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.request import Request, urlopen

from player_fixtures import LoopbackHTTPServer, emby_api_path, serve


class FixtureServerTest(unittest.TestCase):
    def exercise_server(self, check):
        original_serve = LoopbackHTTPServer.serve_forever

        def check_server(server):
            thread = threading.Thread(target=original_serve, args=(server,))
            thread.start()
            try:
                check(f'http://127.0.0.1:{server.server_port}')
            finally:
                server.shutdown()
                thread.join()
                server.server_close()

        with tempfile.TemporaryDirectory() as directory, \
             patch.object(LoopbackHTTPServer, 'serve_forever', check_server):
            serve(Path(directory), Path(directory))

    def test_playback_switches_stay_within_one_confirmed_series(self):
        # Exercise the actual HTTP fixture used by desktop smoke tests. The
        # production playEpisode path retains the first item's work anchor.
        def check_server(base):
            def get_item(identifier):
                with urlopen(f'{base}/emby/Users/validation-user/Items/{identifier}',
                             timeout=5) as response:
                    return json.load(response)

            baseline = get_item('baseline')
            self.assertEqual(baseline['Type'], 'Episode')
            series = get_item(baseline['SeriesId'])
            self.assertEqual(series['Id'], baseline['SeriesId'])
            self.assertEqual(series['Type'], 'Series')
            for identifier in (
                'baseline', 'delayed-report', 'delayed-subtitle', 'tracks',
                'hls', '1080p60', '1080p60-long', '4k-hevc', 'av1', 'vp9',
                'cache-long', 'subtitle-window', 'broken',
            ):
                with self.subTest(item=identifier):
                    item = get_item(identifier)
                    self.assertEqual(item['Id'], identifier)
                    self.assertEqual(item['Type'], 'Episode')
                    self.assertEqual(item['SeriesId'], series['Id'])
                    self.assertEqual(item['ParentId'], series['Id'])

        self.exercise_server(check_server)

    def test_hls_session_can_be_released_and_reconciled_again(self):
        def check_server(base):
            request = Request(base + '/emby/Items/hls/PlaybackInfo',
                              data=b'{}', headers={'Content-Type': 'application/json'})
            with urlopen(request, timeout=5) as response:
                playback = json.load(response)
            self.assertIn('TranscodingUrl', playback['MediaSources'][0])
            session = playback['PlaySessionId']
            # Normal release and host crash reconciliation use the same DELETE.
            for prefix in ('/emby', ''):
                request = Request(
                    f'{base}{prefix}/Videos/ActiveEncodings'
                    f'?DeviceId=validation&PlaySessionId={session}', method='DELETE')
                with urlopen(request, timeout=5) as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(json.load(response), {})

        self.exercise_server(check_server)

    def test_fixture_accepts_canonical_api_and_media_paths(self):
        for path in ('/System/Info/Public', '/Sessions/Playing', '/media/sample.mp4'):
            self.assertEqual(emby_api_path('/emby' + path + '?api_key=synthetic'), path)
            self.assertEqual(emby_api_path(path), path)
        self.assertEqual(emby_api_path('/embywebsocket'), '/embywebsocket')

    def test_server_listens_without_reverse_dns(self):
        with patch('socket.getfqdn', side_effect=AssertionError('DNS must not run')):
            with LoopbackHTTPServer(('127.0.0.1', 0), BaseHTTPRequestHandler) as server:
                self.assertEqual(server.server_name, '127.0.0.1')
                self.assertGreater(server.server_port, 0)
                with socket.create_connection(server.server_address, timeout=2):
                    pass


if __name__ == '__main__':
    unittest.main()
