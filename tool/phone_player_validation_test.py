"""Candidate evidence must bind an audited build and measured artifacts."""

import json
import io
import math
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import wave

from PIL import Image

import phone_player_validation as validation


class PhoneValidationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.apk = self.root / 'android' / 'app-probe.apk'
        self.apk.parent.mkdir()
        self.apk.write_bytes(b'synthetic validation APK')
        self.identity = {'head': 'a' * 40, 'working_tree_sha256': 'b' * 64,
                         'dirty': False}
        self.audited = {'path': 'android/app-probe.apk',
                        'sha256': validation.sha256(self.apk)}
        self.live = {'serial': 'physical-test', 'fingerprint': 'physical/build',
                     'installed_apk_sha256': self.audited['sha256']}

    def _wav(self, name, amplitude):
        path = self.root / name
        with wave.open(str(path), 'wb') as stream:
            stream.setnchannels(1)
            stream.setsampwidth(2)
            stream.setframerate(8000)
            stream.writeframes(b''.join(struct.pack('<h', int(amplitude *
                math.sin(2 * math.pi * 440 * i / 8000))) for i in range(40000)))
        return path

    def probe_reply(self, probe):
        def respond(request, **_):
            state = dict(probe, ended=request.get_method() == 'POST')
            return io.BytesIO(json.dumps(state).encode())
        return respond

    def record(self):
        before = self.root / 'before.png'
        after = self.root / 'after.png'
        Image.new('RGB', (100, 100), 'black').save(before)
        Image.new('RGB', (100, 100), 'red').save(after)
        ambient = self._wav('ambient.wav', 0)
        playback = self._wav('playback.wav', 10000)
        checks = {}
        for name in validation.PHYSICAL_CHECKS:
            observation = {'schema': 2, 'scenario': name,
                           'device_serial': self.live['serial'],
                           'apk_sha256': self.audited['sha256'],
                           'candidate_head': self.identity['head']}
            if name in validation.SCREEN_EVENTS:
                observation.update(events=list(validation.SCREEN_EVENTS[name]),
                    screenBeforePath=before.name,
                    screenBeforeSha256=validation.sha256(before),
                    displayedFrameEvidencePath=after.name,
                    displayedFrameEvidenceSha256=validation.sha256(after),
                    displayedFrameClockUncertaintyMs=5,
                    screenPixelChangeObserved=True,
                    screenRegion=[0, 0, 100, 100])
            if name == 'installed_launch':
                observation.update(package=validation.PACKAGE, launchMs=500)
            if name == 'lock_and_unlock':
                observation.update(anchorBefore=[1, 1, 49, 49],
                    anchorLocked=[1, 1, 49, 49], ordinaryTapStayedLocked=True)
            if name == 'retry_after_outage':
                observation.update(recoveringMs=10, displayedMs=1000)
            if name == 'source_switch_and_rollback':
                observation.update(sourceBefore='source-a', sourceAfter='source-b',
                                   rollbackSource='source-a')
            if name == 'buffered_seek':
                observation.update(offline=True, seekMs=500,
                                   cachedRangesMs=[[0, 1000]])
            if name == 'visible_images_and_scroll':
                observation['firstDisplayedImageMs'] = 100
            if name == 'background_resume':
                observation.update(resumedPaused=True, audioFocusReleased=True)
            if name == 'physical_audio':
                observation.update(ambientWavPath=ambient.name,
                    ambientWavSha256=validation.sha256(ambient),
                    playbackWavPath=playback.name,
                    playbackWavSha256=validation.sha256(playback),
                    microphoneDevice='test microphone')
            if name == 'power_and_thermal':
                observation.update(environment='physical', method='power-rail',
                    samples=[{'elapsedMs': i * 16000, 'energyMWh': i + 1,
                              'tempC': 30 + i * .1, 'brightnessPercent': 50,
                              'volumePercent': 40} for i in range(20)])
            evidence = self.root / f'{name}.json'
            evidence.write_text(json.dumps(observation), encoding='utf-8')
            checks[name] = {'passed': True, 'evidence_path': evidence.name,
                            'sha256': validation.sha256(evidence)}
        return {'candidate_head': self.identity['head'],
                'working_tree_sha256': self.identity['working_tree_sha256'],
                'apk_path': self.audited['path'], 'apk_sha256': self.audited['sha256'],
                'environment': 'physical', 'device_serial': self.live['serial'],
                'device_fingerprint': self.live['fingerprint'], 'checks': checks}

    def validate(self, record):
        return validation.validate_physical(record, self.identity, self.root,
            audited_apk=self.audited, live_device=self.live)

    def bind_mock_adb_captures_and_attestation(self, record):
        before = (self.root / 'before.png').read_bytes()
        after = (self.root / 'after.png').read_bytes()
        def fake_adb(args, **_):
            self.assertEqual(args, ['adb', '-s', self.live['serial'],
                                    'exec-out', 'screencap', '-p'])
            phase = fake_adb.count % 2
            fake_adb.count += 1
            return subprocess.CompletedProcess(args, 0, before if phase == 0 else after, b'')
        fake_adb.count = 0
        foreground = subprocess.CompletedProcess([], 0,
            'topResumedActivity=ActivityRecord{ com.rillight.rillight.validation/com.rillight.rillight.MainActivity }', '')
        with patch.object(validation.subprocess, 'run', side_effect=fake_adb), \
                patch.object(validation, 'command', return_value=foreground):
            for name in validation.SCREEN_EVENTS:
                captured = [validation.capture_live_screen(
                    self.root, name, phase, self.identity, self.audited, self.live)
                    for phase in ('before', 'after')]
                file = self.root / f'{name}.json'
                observation = json.loads(file.read_text(encoding='utf-8'))
                observation.update(screenBeforePath=captured[0]['path'],
                    screenBeforeSha256=captured[0]['sha256'],
                    displayedFrameEvidencePath=captured[1]['path'],
                    displayedFrameEvidenceSha256=captured[1]['sha256'])
                file.write_text(json.dumps(observation), encoding='utf-8')
                record['checks'][name]['sha256'] = validation.sha256(file)
        attestation = self.root / 'physical-audio-attestation.json'
        attestation.write_text(json.dumps({
            'schema': 1, 'kind': 'physical-speaker-listening',
            'physicalSpeakerAudible': True, 'speakerRoute': 'built-in-speaker',
            'attestedBy': 'Contract Test Observer',
            'observedAtUtc': '2026-09-27T00:00:00Z',
            'device_serial': self.live['serial'],
            'apk_sha256': self.audited['sha256'],
            'candidate_head': self.identity['head']}), encoding='utf-8')
        file = self.root / 'physical_audio.json'
        observation = json.loads(file.read_text(encoding='utf-8'))
        observation.update(manualAttestationPath=attestation.name,
                           manualAttestationSha256=validation.sha256(attestation))
        file.write_text(json.dumps(observation), encoding='utf-8')
        record['checks']['physical_audio']['sha256'] = validation.sha256(file)

    def test_missing_or_disconnected_observations_fail_closed(self):
        self.assertIn('Physical phone evidence is missing', self.validate(None))
        record = self.record()
        self.assertIn('Connected physical Android phone observation unavailable',
            validation.validate_physical(record, self.identity, self.root,
                                         audited_apk=self.audited))

    def test_typed_artifacts_bind_audited_and_installed_apk(self):
        record = self.record()
        self.assertTrue(any('displayed_changing_video' in error for error in self.validate(record)))
        self.assertTrue(any('physical_audio' in error for error in self.validate(record)))
        self.bind_mock_adb_captures_and_attestation(record)
        self.assertEqual(self.validate(record), [])
        record['apk_path'] = 'other.apk'
        self.assertTrue(any('audited runner build' in error for error in self.validate(record)))
        record['apk_path'] = self.audited['path']
        self.live['installed_apk_sha256'] = '0' * 64
        self.assertTrue(any('installed APK' in error for error in self.validate(record)))

    def test_self_asserted_json_and_unchanged_pixels_are_rejected(self):
        record = self.record()
        evidence = self.root / 'lock_and_unlock.json'
        evidence.write_text(json.dumps({'synthetic': True}), encoding='utf-8')
        record['checks']['lock_and_unlock']['sha256'] = validation.sha256(evidence)
        self.assertTrue(any('lock_and_unlock' in error for error in self.validate(record)))
        record = self.record()
        self.bind_mock_adb_captures_and_attestation(record)
        observation = self.root / 'displayed_changing_video.json'
        value = json.loads(observation.read_text())
        value['displayedFrameEvidencePath'] = 'before.png'
        value['displayedFrameEvidenceSha256'] = validation.sha256(self.root / 'before.png')
        observation.write_text(json.dumps(value), encoding='utf-8')
        record['checks']['displayed_changing_video']['sha256'] = validation.sha256(observation)
        self.assertTrue(any('displayed_changing_video' in error for error in self.validate(record)))

    def test_capture_ledger_tampering_and_unbound_wav_cannot_pass(self):
        record = self.record()
        self.bind_mock_adb_captures_and_attestation(record)
        self.assertEqual(self.validate(record), [])
        ledger = self.root / 'capture-ledger.json'
        rows = json.loads(ledger.read_text())
        rows[0]['payload']['sha256'] = '0' * 64
        ledger.write_text(json.dumps(rows), encoding='utf-8')
        self.assertTrue(any('installed_launch' in error for error in self.validate(record)))
        record = self.record()
        self.bind_mock_adb_captures_and_attestation(record)
        audio = self.root / 'physical_audio.json'
        observation = json.loads(audio.read_text())
        observation.pop('manualAttestationPath')
        observation.pop('manualAttestationSha256')
        audio.write_text(json.dumps(observation), encoding='utf-8')
        record['checks']['physical_audio']['sha256'] = validation.sha256(audio)
        self.assertTrue(any('physical_audio' in error for error in self.validate(record)))

    def test_capture_rejects_another_foreground_app(self):
        other = subprocess.CompletedProcess([], 0,
            'topResumedActivity=ActivityRecord{ com.example.other/.MainActivity }', '')
        with patch.object(validation, 'command', return_value=other), \
                patch.object(validation.subprocess, 'run') as screencap:
            with self.assertRaisesRegex(RuntimeError, 'foreground'):
                validation.capture_live_screen(self.root, 'displayed_changing_video',
                    'before', self.identity, self.audited, self.live)
            screencap.assert_not_called()

    def test_evidence_cannot_escape_root(self):
        record = self.record()
        record['checks']['physical_audio']['evidence_path'] = '../elsewhere.json'
        self.assertTrue(any('physical_audio' in error for error in self.validate(record)))

    def test_reusable_manifest_requires_same_source_and_audited_bytes(self):
        result = self.root / 'android' / 'result.json'
        result.write_text(json.dumps({'passed': True,
            'source': {'head': self.identity['head'], 'dirty': False},
            'app_apk': {'sha256': self.audited['sha256'], 'package': validation.PACKAGE,
                        'native': {'core_abis': ['arm64-v8a', 'armeabi-v7a', 'x86_64'],
                            'libraries': {abi: {'librillight_core.so': {},
                                                'librillight_android_core.so': {}}
                                          for abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']},
                            'notice_hashes': {'synthetic': 'a' * 64}}},
            'devices': [{'passed': True, 'tv': False, 'width_dp': 360},
                        {'passed': True, 'tv': False, 'width_dp': 412},
                        {'passed': True, 'tv': True, 'width_dp': 960}]}), encoding='utf-8')
        manifest = {'candidate_head': self.identity['head'],
                    'working_tree_sha256': self.identity['working_tree_sha256'],
                    'result_path': 'android/result.json',
                    'result_sha256': validation.sha256(result),
                    'apk_path': self.audited['path'],
                    'apk_sha256': self.audited['sha256']}
        (self.root / 'candidate-build.json').write_text(json.dumps(manifest), encoding='utf-8')
        self.assertIsNotNone(validation.audited_android_candidate(self.root, self.identity))
        self.apk.write_bytes(b'changed APK')
        self.assertIsNone(validation.audited_android_candidate(self.root, self.identity))

    def test_frozen_baseline_manifest_binds_source_tree_and_apk(self):
        baseline_root = self.root / 'performance' / 'baseline'
        baseline_root.mkdir(parents=True)
        apk = baseline_root / 'frozen.apk'
        apk.write_bytes(b'frozen source build')
        audit = baseline_root / 'apk-audit.json'
        audit.write_text(json.dumps({'sha256': validation.sha256(apk),
            'package': validation.PACKAGE,
            'native': {'core_abis': ['arm64-v8a', 'armeabi-v7a', 'x86_64'],
                       'notice_hashes': {'synthetic': 'a' * 64}}}), encoding='utf-8')
        log = baseline_root / 'build.log'
        log.write_text('profile build completed', encoding='utf-8')
        identity = validation.frozen_baseline_identity()
        manifest = {'source_head': identity['head'],
            'source_tree': validation.FROZEN_BASELINE_TREE,
            'source_working_tree_sha256': identity['working_tree_sha256'],
            'probe_sha256': identity['working_tree_sha256'],
            'build_mode': 'profile',
            'entrypoint': 'integration_test/mobile_performance.dart',
            'apk_path': apk.name, 'apk_sha256': validation.sha256(apk),
            'audit_path': audit.name, 'audit_sha256': validation.sha256(audit),
            'build_log_path': log.name, 'build_log_sha256': validation.sha256(log)}
        key = validation._capture_key(self.root, create=True)
        manifest['signature'] = validation._capture_signature(key, manifest)
        manifest_path = baseline_root / 'build.json'
        manifest_path.write_text(json.dumps(manifest), encoding='utf-8')
        self.assertIsNotNone(validation.frozen_baseline_artifact(self.root))
        manifest['source_head'] = 'c' * 40
        manifest.pop('signature')
        manifest['signature'] = validation._capture_signature(key, manifest)
        manifest_path.write_text(json.dumps(manifest), encoding='utf-8')
        self.assertIsNone(validation.frozen_baseline_artifact(self.root))

    def test_performance_rows_must_use_audited_apk_and_live_phone(self):
        samples = self.root / 'candidate.jsonl'
        row = {'phase': 'candidate', 'target': 'android-phone',
               'device': self.live['fingerprint'],
               'artifactPath': self.audited['path'],
               'artifactSha256': self.audited['sha256'],
               'category': 'page', 'label': 'home', 'cache': 'cold',
               'buildMode': 'profile', 'firstOperableMs': 500,
               'complete': True, 'frameBudgetMs': 16.67}
        samples.write_text(json.dumps(row), encoding='utf-8')
        self.assertFalse(validation.candidate_samples_match_apk(
            samples, self.audited, self.live['fingerprint'], self.root))
        screen = io.BytesIO()
        Image.new('RGB', (100, 100), 'red').save(screen, format='PNG')
        foreground = subprocess.CompletedProcess([], 0,
            'topResumedActivity=ActivityRecord{ com.rillight.rillight.validation/.MainActivity }', '')
        probe = {'platform': 'android', 'buildMode': 'profile',
                 'elapsedMs': 1000, 'firstOperableMs': 500,
                 'runId': '1' * 32, 'ended': True,
                 'complete': True, 'frameBudgetMs': 16.67,
                 'label': 'home', 'cache': 'cold', 'device': self.live['fingerprint']}
        with patch.object(validation.subprocess, 'run', return_value=
                          subprocess.CompletedProcess([], 0, screen.getvalue(), b'')), \
                patch.object(validation, 'command', return_value=foreground), \
                patch.object(validation, 'urlopen', side_effect=self.probe_reply(probe)):
            capture = validation.capture_live_performance(
                self.root, 'page', 'after', 'candidate', self.identity,
                self.audited, self.live)
        row['probeTraceId'] = capture['id']
        samples.write_text(json.dumps(row), encoding='utf-8')
        self.assertTrue(validation.candidate_samples_match_apk(
            samples, self.audited, self.live['fingerprint'], self.root, self.identity))
        row['firstOperableMs'] = 1
        samples.write_text(json.dumps(row), encoding='utf-8')
        self.assertFalse(validation.candidate_samples_match_apk(
            samples, self.audited, self.live['fingerprint'], self.root, self.identity))
        row['firstOperableMs'] = 500
        samples.write_text(json.dumps(row) + '\n' + json.dumps(row), encoding='utf-8')
        self.assertFalse(validation.candidate_samples_match_apk(
            samples, self.audited, self.live['fingerprint'], self.root, self.identity))
        row['artifactPath'] = 'other.apk'
        samples.write_text(json.dumps(row), encoding='utf-8')
        self.assertFalse(validation.candidate_samples_match_apk(
            samples, self.audited, self.live['fingerprint'], self.root))

    def test_display_timing_requires_live_capture_and_probe_elapsed(self):
        frames = []
        for color in ('black', 'red'):
            frame = io.BytesIO()
            Image.new('RGB', (100, 100), color).save(frame, format='PNG')
            frames.append(frame.getvalue())
        def fake_adb(args, **_):
            result = subprocess.CompletedProcess(args, 0, frames[fake_adb.count], b'')
            fake_adb.count += 1
            return result
        fake_adb.count = 0
        foreground = subprocess.CompletedProcess([], 0,
            'topResumedActivity=ActivityRecord{ com.rillight.rillight.validation/.MainActivity }', '')
        probe = {'platform': 'android', 'buildMode': 'profile',
                 'elapsedMs': 1000, 'renderedImageObserved': True,
                 'runId': '2' * 32, 'ended': True,
                 'complete': True, 'frameBudgetMs': 16.67,
                 'label': 'home', 'cache': 'cold', 'device': self.live['fingerprint']}
        with patch.object(validation.subprocess, 'run', side_effect=fake_adb), \
                patch.object(validation, 'command', return_value=foreground), \
                patch.object(validation, 'urlopen', side_effect=self.probe_reply(probe)):
            before = validation.capture_live_performance(
                self.root, 'image', 'before', 'candidate', self.identity,
                self.audited, self.live)
            after = validation.capture_live_performance(
                self.root, 'image', 'after', 'candidate', self.identity,
                self.audited, self.live)
        trace = json.loads((self.root / after['path']).read_text())
        screenshot = trace['screenshot']
        row = {'phase': 'candidate', 'target': 'android-phone',
               'category': 'image', 'label': 'home', 'cache': 'cold',
               'device': self.live['fingerprint'], 'buildMode': 'profile',
               'complete': True, 'frameBudgetMs': 16.67,
               'artifactPath': self.audited['path'],
               'artifactSha256': self.audited['sha256'],
               'probeTraceId': after['id'], 'renderedImageObserved': True,
               'elapsedMs': 1000, 'firstDisplayedImageMs': 1000,
               'screenBeforePath': before['path'],
               'screenBeforeSha256': before['sha256'],
               'displayedImageEvidencePath': screenshot['path'],
               'displayedImageEvidenceSha256': screenshot['sha256']}
        samples = self.root / 'candidate.jsonl'
        samples.write_text(json.dumps(row), encoding='utf-8')
        self.assertTrue(validation.candidate_samples_match_apk(
            samples, self.audited, self.live['fingerprint'], self.root, self.identity))
        row['firstDisplayedImageMs'] = 1
        samples.write_text(json.dumps(row), encoding='utf-8')
        self.assertFalse(validation.candidate_samples_match_apk(
            samples, self.audited, self.live['fingerprint'], self.root, self.identity))
        row['firstDisplayedImageMs'] = 1000
        row['category'] = 'power'
        samples.write_text(json.dumps(row), encoding='utf-8')
        self.assertFalse(validation.candidate_samples_match_apk(
            samples, self.audited, self.live['fingerprint'], self.root, self.identity))

    def test_baseline_trace_can_use_distinct_installed_apk(self):
        baseline_apk = self.root / 'baseline' / 'baseline.apk'
        baseline_apk.parent.mkdir()
        baseline_apk.write_bytes(b'prior validation APK')
        baseline_artifact = {'path': 'baseline/' + baseline_apk.name,
                             'sha256': validation.sha256(baseline_apk)}
        baseline_live = dict(self.live, installed_apk_sha256=baseline_artifact['sha256'])
        baseline_identity = validation.frozen_baseline_identity()
        screenshot = io.BytesIO()
        Image.new('RGB', (100, 100), 'blue').save(screenshot, format='PNG')
        foreground = subprocess.CompletedProcess([], 0,
            'topResumedActivity=ActivityRecord{ com.rillight.rillight.validation/.MainActivity }', '')
        probe = {'platform': 'android', 'buildMode': 'profile',
                 'elapsedMs': 1000, 'firstOperableMs': 800,
                 'runId': '3' * 32, 'ended': True,
                 'complete': True, 'frameBudgetMs': 16.67,
                 'label': 'home', 'cache': 'cold', 'device': self.live['fingerprint']}
        with patch.object(validation.subprocess, 'run', return_value=
                          subprocess.CompletedProcess([], 0, screenshot.getvalue(), b'')), \
                patch.object(validation, 'command', return_value=foreground), \
                patch.object(validation, 'urlopen', side_effect=self.probe_reply(probe)):
            capture = validation.capture_live_performance(
                self.root, 'page', 'after', 'baseline', baseline_identity,
                baseline_artifact, baseline_live)
        row = {'phase': 'baseline', 'target': 'android-phone',
               'category': 'page', 'label': 'home', 'cache': 'cold',
               'device': self.live['fingerprint'], 'buildMode': 'profile',
               'artifactPath': 'baseline/' + baseline_apk.name,
               'artifactSha256': baseline_artifact['sha256'],
               'probeTraceId': capture['id'], 'firstOperableMs': 800,
               'complete': True, 'frameBudgetMs': 16.67}
        samples = self.root / 'baseline.jsonl'
        samples.write_text(json.dumps(row), encoding='utf-8')
        self.assertTrue(validation.samples_match_live_probes(
            samples, 'baseline', baseline_artifact, self.live['fingerprint'], self.root))
        row['artifactSha256'] = self.audited['sha256']
        samples.write_text(json.dumps(row), encoding='utf-8')
        self.assertFalse(validation.samples_match_live_probes(
            samples, 'baseline', baseline_artifact, self.live['fingerprint'], self.root))

    def test_replayed_run_id_is_rejected_even_with_new_trace_id(self):
        frame = io.BytesIO()
        Image.new('RGB', (100, 100), 'red').save(frame, format='PNG')
        foreground = subprocess.CompletedProcess([], 0,
            'topResumedActivity=ActivityRecord{ com.rillight.rillight.validation/.MainActivity }', '')
        probe = {'platform': 'android', 'buildMode': 'profile',
                 'elapsedMs': 1000, 'firstOperableMs': 500,
                 'runId': '4' * 32, 'complete': True, 'frameBudgetMs': 16.67,
                 'label': 'home', 'cache': 'cold', 'device': self.live['fingerprint']}
        with patch.object(validation.subprocess, 'run', return_value=
                          subprocess.CompletedProcess([], 0, frame.getvalue(), b'')), \
                patch.object(validation, 'command', return_value=foreground), \
                patch.object(validation, 'urlopen', side_effect=self.probe_reply(probe)):
            traces = [validation.capture_live_performance(
                self.root, 'page', 'after', 'candidate', self.identity,
                self.audited, self.live) for _ in range(2)]
        rows = [{'phase': 'candidate', 'target': 'android-phone',
                 'device': self.live['fingerprint'],
                 'artifactPath': self.audited['path'],
                 'artifactSha256': self.audited['sha256'],
                 'category': 'page', 'label': 'home', 'cache': 'cold',
                 'buildMode': 'profile', 'firstOperableMs': 500,
                 'complete': True, 'frameBudgetMs': 16.67,
                 'probeTraceId': trace['id']} for trace in traces]
        samples = self.root / 'candidate.jsonl'
        samples.write_text('\n'.join(json.dumps(row) for row in rows), encoding='utf-8')
        self.assertFalse(validation.candidate_samples_match_apk(
            samples, self.audited, self.live['fingerprint'], self.root, self.identity))

    def test_live_network_stall_uses_signed_capture_timestamps(self):
        frames = []
        for color in ('black', 'red'):
            frame = io.BytesIO()
            Image.new('RGB', (100, 100), color).save(frame, format='PNG')
            frames.append(frame.getvalue())
        def fake_adb(args, **_):
            response = subprocess.CompletedProcess(args, 0, frames[fake_adb.count], b'')
            fake_adb.count += 1
            return response
        fake_adb.count = 0
        foreground = subprocess.CompletedProcess([], 0,
            'topResumedActivity=ActivityRecord{ com.rillight.rillight.validation/.MainActivity }', '')
        probe = {'platform': 'android', 'buildMode': 'profile',
                 'elapsedMs': 3500, 'runId': '5' * 32,
                 'complete': True, 'frameBudgetMs': 16.67,
                 'label': 'outage', 'cache': 'cold', 'device': self.live['fingerprint']}
        with patch.object(validation.subprocess, 'run', side_effect=fake_adb), \
                patch.object(validation, 'command', return_value=foreground), \
                patch.object(validation, 'urlopen', side_effect=self.probe_reply(probe)), \
                patch.object(validation.time, 'time_ns', side_effect=
                             [1000000000000000, 1000002000000000]):
            before = validation.capture_live_performance(
                self.root, 'network', 'before', 'candidate', self.identity,
                self.audited, self.live)
            after = validation.capture_live_performance(
                self.root, 'network', 'after', 'candidate', self.identity,
                self.audited, self.live)
        screenshot = json.loads((self.root / after['path']).read_text())['screenshot']
        row = {'phase': 'candidate', 'target': 'android-phone', 'category': 'network',
               'label': 'outage', 'cache': 'cold', 'device': self.live['fingerprint'],
               'buildMode': 'profile', 'complete': True, 'frameBudgetMs': 16.67,
               'artifactPath': self.audited['path'],
               'artifactSha256': self.audited['sha256'], 'probeTraceId': after['id'],
               'elapsedMs': 3500, 'stallMs': 2000,
               'screenBeforePath': before['path'], 'screenBeforeSha256': before['sha256'],
               'displayedFrameEvidencePath': screenshot['path'],
               'displayedFrameEvidenceSha256': screenshot['sha256']}
        samples = self.root / 'candidate.jsonl'
        samples.write_text(json.dumps(row), encoding='utf-8')
        self.assertTrue(validation.candidate_samples_match_apk(
            samples, self.audited, self.live['fingerprint'], self.root, self.identity))
        row['stallMs'] = 1
        samples.write_text(json.dumps(row), encoding='utf-8')
        self.assertFalse(validation.candidate_samples_match_apk(
            samples, self.audited, self.live['fingerprint'], self.root, self.identity))

    def test_physical_meter_log_attestation_derives_power_and_thermal(self):
        foreground = subprocess.CompletedProcess([], 0,
            'topResumedActivity=ActivityRecord{ com.rillight.rillight.validation/.MainActivity }', '')
        for category, run_id, field in (
                ('power', '6' * 32, 'energyMWh'),
                ('thermal', '7' * 32, 'tempC')):
            with self.subTest(category=category):
                frames = []
                for color in ('black', 'red'):
                    frame = io.BytesIO()
                    Image.new('RGB', (100, 100), color).save(frame, format='PNG')
                    frames.append(frame.getvalue())
                def fake_adb(args, **_):
                    response = subprocess.CompletedProcess(args, 0,
                        frames[fake_adb.count], b'')
                    fake_adb.count += 1
                    return response
                fake_adb.count = 0
                probe = {'platform': 'android', 'buildMode': 'profile',
                         'elapsedMs': 310000, 'runId': run_id,
                         'complete': True, 'frameBudgetMs': 16.67,
                         'label': category, 'cache': 'cold',
                         'device': self.live['fingerprint']}
                raw = self.root / f'{category}-meter-log.json'
                raw.write_text(json.dumps([
                    {'elapsedMs': i * 16000,
                     field: (1000 + i * 2 if category == 'power' else 30 + i * .1)}
                    for i in range(20)]), encoding='utf-8')
                attestation = self.root / f'{category}-attestation.json'
                attestation.write_text(json.dumps({
                    'schema': 1, 'kind': 'physical-meter-attestation',
                    'category': category,
                    'method': 'power-rail' if category == 'power' else 'thermal-zone',
                    'runId': run_id, 'deviceSerial': self.live['serial'],
                    'apkSha256': self.audited['sha256'],
                    'attestedBy': 'Meter Observer',
                    'observedAtUtc': '2026-09-27T00:00:00Z',
                    'instrumentModel': 'Physical Meter', 'instrumentSerial': 'M-1',
                    'uncertaintyPercent': 3, 'initialTempC': 30,
                    'brightnessPercent': 50, 'volumePercent': 40,
                    'rawLogPath': raw.name, 'rawLogSha256': validation.sha256(raw)}),
                    encoding='utf-8')
                with patch.object(validation.subprocess, 'run', side_effect=fake_adb), \
                        patch.object(validation, 'command', return_value=foreground), \
                        patch.object(validation, 'urlopen',
                                     side_effect=self.probe_reply(probe)), \
                        patch.object(validation.time, 'time_ns', side_effect=
                                     [1000000000000000, 1000304000000000]):
                    before = validation.capture_live_performance(
                        self.root, category, 'before', 'candidate', self.identity,
                        self.audited, self.live)
                    after = validation.capture_live_performance(
                        self.root, category, 'after', 'candidate', self.identity,
                        self.audited, self.live, measurement_file=attestation)
                trace = json.loads((self.root / after['path']).read_text())
                screenshot = trace['screenshot']
                row = {'phase': 'candidate', 'target': 'android-phone',
                       'category': category, 'label': category, 'cache': 'cold',
                       'device': self.live['fingerprint'], 'buildMode': 'profile',
                       'complete': True, 'frameBudgetMs': 16.67,
                       'artifactPath': self.audited['path'],
                       'artifactSha256': self.audited['sha256'],
                       'probeTraceId': after['id'], 'elapsedMs': 310000,
                       'environment': 'physical',
                       'measurementMethod': ('power-rail' if category == 'power'
                                             else 'thermal-zone'),
                       'initialTempC': 30, 'brightnessPercent': 50,
                       'volumePercent': 40,
                       'screenBeforePath': before['path'],
                       'screenBeforeSha256': before['sha256'],
                       'displayedFrameEvidencePath': screenshot['path'],
                       'displayedFrameEvidenceSha256': screenshot['sha256'],
                       ('energyMWh' if category == 'power' else 'tempRiseC'):
                           trace['measurement']['metric']}
                samples = self.root / 'candidate.jsonl'
                samples.write_text(json.dumps(row), encoding='utf-8')
                self.assertTrue(validation.candidate_samples_match_apk(
                    samples, self.audited, self.live['fingerprint'], self.root,
                    self.identity))
                raw.write_text('[]', encoding='utf-8')
                self.assertFalse(validation.candidate_samples_match_apk(
                    samples, self.audited, self.live['fingerprint'], self.root,
                    self.identity))


if __name__ == '__main__':
    unittest.main()
