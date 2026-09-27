"""Contract checks for candidate-bound phone evidence."""

import json
from pathlib import Path
import tempfile
import unittest

import phone_player_validation as validation


class PhoneValidationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.apk = self.root / 'candidate.apk'
        self.apk.write_bytes(b'synthetic candidate')
        self.identity = {'head': 'a' * 40, 'working_tree_sha256': 'b' * 64}

    def record(self):
        checks = {}
        for name in validation.PHYSICAL_CHECKS:
            evidence = self.root / f'{name}.json'
            evidence.write_text(json.dumps({'synthetic': True}), encoding='utf-8')
            checks[name] = {'passed': True, 'evidence_path': evidence.name,
                            'sha256': validation.sha256(evidence)}
        return {'candidate_head': self.identity['head'],
                'working_tree_sha256': self.identity['working_tree_sha256'],
                'apk_path': self.apk.name, 'apk_sha256': validation.sha256(self.apk),
                'environment': 'physical', 'device_fingerprint': 'synthetic-device',
                'checks': checks}

    def test_missing_observations_fail_closed(self):
        self.assertIn('Physical phone evidence is missing',
                      validation.validate_physical(None, self.identity, self.root))

    def test_candidate_hash_and_each_artifact_are_verified(self):
        record = self.record()
        self.assertEqual(validation.validate_physical(record, self.identity, self.root), [])
        (self.root / 'displayed_changing_video.json').write_bytes(b'changed')
        errors = validation.validate_physical(record, self.identity, self.root)
        self.assertTrue(any('displayed_changing_video' in item for item in errors))
        record['candidate_head'] = 'c' * 40
        errors = validation.validate_physical(record, self.identity, self.root)
        self.assertTrue(any('another source candidate' in item for item in errors))

    def test_evidence_cannot_escape_root(self):
        record = self.record()
        record['checks']['physical_audio']['evidence_path'] = '../elsewhere.json'
        errors = validation.validate_physical(record, self.identity, self.root)
        self.assertTrue(any('physical_audio' in item for item in errors))


if __name__ == '__main__':
    unittest.main()
