"""Candidate evidence must bind an audited build and measured artifacts."""

import json
import math
from pathlib import Path
import struct
import tempfile
import unittest
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

    def test_missing_or_disconnected_observations_fail_closed(self):
        self.assertIn('Physical phone evidence is missing', self.validate(None))
        record = self.record()
        self.assertIn('Connected physical Android phone observation unavailable',
            validation.validate_physical(record, self.identity, self.root,
                                         audited_apk=self.audited))

    def test_typed_artifacts_bind_audited_and_installed_apk(self):
        record = self.record()
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
        observation = self.root / 'displayed_changing_video.json'
        value = json.loads(observation.read_text())
        value['displayedFrameEvidencePath'] = 'before.png'
        value['displayedFrameEvidenceSha256'] = validation.sha256(self.root / 'before.png')
        observation.write_text(json.dumps(value), encoding='utf-8')
        record['checks']['displayed_changing_video']['sha256'] = validation.sha256(observation)
        self.assertTrue(any('displayed_changing_video' in error for error in self.validate(record)))

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

    def test_performance_rows_must_use_audited_apk_and_live_phone(self):
        samples = self.root / 'candidate.jsonl'
        row = {'phase': 'candidate', 'target': 'android-phone',
               'device': self.live['fingerprint'],
               'artifactPath': self.audited['path'],
               'artifactSha256': self.audited['sha256']}
        samples.write_text(json.dumps(row), encoding='utf-8')
        self.assertTrue(validation.candidate_samples_match_apk(
            samples, self.audited, self.live['fingerprint'], self.root))
        row['artifactPath'] = 'other.apk'
        samples.write_text(json.dumps(row), encoding='utf-8')
        self.assertFalse(validation.candidate_samples_match_apk(
            samples, self.audited, self.live['fingerprint'], self.root))


if __name__ == '__main__':
    unittest.main()
