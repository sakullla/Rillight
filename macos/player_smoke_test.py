"""Check hosted-runner control evidence without claiming pixel/audio validation."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import player_smoke


class PlaybackScopeTest(unittest.TestCase):
    def exercise(self, *, skip_capture, controls_pass=True, capture_status=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'Rillight.app'
            executable = app / 'Contents/MacOS/Rillight'
            executable.parent.mkdir(parents=True)
            executable.touch()
            processes = []
            streams = []

            def popen(command, **kwargs):
                processes.append(command)
                streams.extend(value for key, value in kwargs.items()
                               if key in ('stdout', 'stderr') and
                               hasattr(value, 'close'))
                output = (root / 'Library/Containers' / player_smoke.BUNDLE_ID /
                          'Data/rillight-validation/run')
                process = Mock()
                process.poll.return_value = 0
                process.returncode = 0
                process.wait.return_value = capture_status
                if any(str(value).endswith('player_fixtures.py') for value in command):
                    (output / 'server.json').write_text('{}')
                elif command[0] == str(executable):
                    (output / 'result.json').write_text(json.dumps(
                        {'passed': controls_pass}))
                else:
                    (output / 'window-evidence.json').write_text(json.dumps(
                        {name: {} for name in (
                            '1080p60-loaded', '4k-hevc-loaded', 'av1-loaded',
                            'vp9-loaded', '1080p60-danmaku-loaded',
                            '1080p60-rate125-loaded', '1080p60-resized-loaded',
                            '1080p60-fullscreen-loaded', '1080p60-rate2-loaded')}))
                return process

            env = {
                'RILLIGHT_MACOS_CORE_PREFIX': str(root / 'sdk'),
                'RILLIGHT_MACOS_CORE_DYLIB': str(root / 'core.dylib'),
                'RILLIGHT_MACOS_CORE_SHA256': 'a' * 64,
            }
            with patch.object(player_smoke, 'ROOT', root), \
                 patch.object(player_smoke, 'APP', app), \
                 patch.object(player_smoke, 'EXECUTABLE', executable), \
                 patch.object(player_smoke, 'PYTHON_APP', root / 'no-python-app'), \
                 patch.object(player_smoke, 'core_env', return_value=env), \
                 patch.object(player_smoke.Path, 'home', return_value=root), \
                 patch.object(player_smoke.time, 'strftime', return_value='run'), \
                 patch.object(player_smoke.shutil, 'which', return_value='ffmpeg'), \
                 patch.object(player_smoke, 'run'), \
                 patch.object(player_smoke.subprocess, 'Popen', side_effect=popen):
                try:
                    if controls_pass:
                        player_smoke.smoke(skip_build=True, skip_restore=True,
                                           skip_window_capture=skip_capture)
                    else:
                        with self.assertRaisesRegex(RuntimeError, 'Playback validation failed'):
                            player_smoke.smoke(skip_build=True, skip_restore=True,
                                               skip_window_capture=skip_capture)
                finally:
                    for stream in streams:
                        stream.close()
            scope = json.loads((root / 'build/player-validation/macos-runs/run' /
                                'validation-scope.json').read_text())
            self.assertEqual(scope['physical_audio'], 'not_run')
            self.assertEqual(scope['hardware_acceptance'], 'not_run')
            return scope, processes

    def test_controls_only_does_not_launch_capture_or_claim_frames(self):
        scope, processes = self.exercise(skip_capture=True)
        self.assertEqual(len(processes), 2)
        self.assertEqual(scope['playback_controls'], 'passed')
        self.assertEqual(scope['window_capture'], 'not_run')

    def test_controls_failure_still_fails_with_capture_disabled(self):
        scope, _ = self.exercise(skip_capture=True, controls_pass=False)
        self.assertEqual(scope['playback_controls'], 'failed')
        self.assertEqual(scope['window_capture'], 'not_run')

    def test_default_retains_window_capture(self):
        scope, processes = self.exercise(skip_capture=False)
        self.assertEqual(len(processes), 3)
        self.assertEqual(scope['window_capture'], 'passed')

    def test_capture_failure_is_recorded_separately(self):
        scope, _ = self.exercise(skip_capture=False, capture_status=1)
        self.assertEqual(scope['playback_controls'], 'passed')
        self.assertEqual(scope['window_capture'], 'failed')


if __name__ == '__main__':
    unittest.main()
