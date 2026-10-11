#!/usr/bin/env python3
"""Adversarial checks of the runner's evidence boundary (no Flutter subprocess)."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import provider_acceptance as acceptance


def events(names=None):
    names = sorted(acceptance.REQUIRED if names is None else names)
    result = [{"type": "suite", "suite": {"id": 0, "path": "/repo/" + acceptance.LOOP_SUITE}}]
    for identity, name in enumerate(names):
        result.extend([
            {"type": "testStart", "test": {"id": identity, "name": name, "suiteID": 0}},
            {"type": "testDone", "testID": identity, "result": "success", "skipped": False, "hidden": False},
        ])
    result.append({"type": "done", "success": True})
    return result


def encoded(rows):
    return "\n".join(json.dumps(row) for row in rows)


class MachineEvidenceTests(unittest.TestCase):
    def verify(self, rows):
        return acceptance.inspect_machine_log(encoded(rows), acceptance.REQUIRED)

    def test_success_requires_executed_scenarios(self):
        result = self.verify(events())
        self.assertEqual(result["passed"], 7)

    def test_success_flag_and_definition_names_are_not_execution(self):
        for raw in ('{"status":"passed"}', "\n".join(acceptance.REQUIRED)):
            with self.assertRaises(acceptance.VerificationError):
                acceptance.inspect_machine_log(raw, acceptance.REQUIRED)

    def test_truncated_run_rejected(self):
        rows = events()
        with self.assertRaises(acceptance.VerificationError):
            self.verify(rows[:-1])
        del rows[2]
        with self.assertRaises(acceptance.VerificationError):
            self.verify(rows)

    def test_missing_provider_rejected(self):
        with self.assertRaises(acceptance.VerificationError):
            self.verify(events([name for name in acceptance.REQUIRED if "plex" not in name]))

    def test_failure_skip_hidden_and_wrong_source_rejected(self):
        for key, value in (("result", "failure"), ("skipped", True), ("hidden", True)):
            with self.subTest(key=key):
                rows = events()
                rows[2][key] = value
                with self.assertRaises(acceptance.VerificationError):
                    self.verify(rows)
        rows = events()
        rows[0]["suite"]["path"] = "/repo/pretend_test.dart"
        with self.assertRaises(acceptance.VerificationError):
            self.verify(rows)

    def test_duplicate_execution_and_orphan_completion_rejected(self):
        rows = events()
        rows.insert(3, rows[2])
        with self.assertRaises(acceptance.VerificationError):
            self.verify(rows)
        rows = events()
        del rows[1]
        with self.assertRaises(acceptance.VerificationError):
            self.verify(rows)

    def test_runner_error_overrides_pass(self):
        rows = events()
        rows.insert(-1, {"type": "error", "error": "late teardown failed"})
        with self.assertRaises(acceptance.VerificationError):
            self.verify(rows)

    def test_empty_run_is_not_pass(self):
        with self.assertRaises(acceptance.VerificationError):
            acceptance.inspect_machine_log(encoded(events([])))

    def test_fabricated_import_cannot_substitute_for_fresh_run(self):
        # An attacker can write a perfect machine log and recalculate all hashes.
        # Imported bytes therefore have no authority, regardless of their shape.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "protocol.jsonl").write_text(encoded(events()), encoding="utf-8")
            (root / "result.json").write_text(json.dumps({"status": "passed", "candidate": "current"}), encoding="utf-8")
            for path in (root, root / "missing", root / "result.json"):
                with self.assertRaisesRegex(acceptance.VerificationError, "not trusted"):
                    acceptance.reject_imported_evidence(str(path))

    def test_unsupported_schema_old_hash_and_missing_cases_are_rejected_imports(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "result.json"
            for document in (
                {"schema": "unsupported-v999", "status": "passed"},
                {"schema": acceptance.SCHEMA, "status": "passed", "candidate": {"worktree_sha256": "old"}},
                {"schema": acceptance.SCHEMA, "status": "passed", "commands": []},
                {"schema": acceptance.SCHEMA, "status": "passed", "scenarios": sorted(acceptance.REQUIRED)[:-1]},
            ):
                with self.subTest(document=document):
                    report.write_text(json.dumps(document), encoding="utf-8")
                    with self.assertRaises(acceptance.VerificationError):
                        acceptance.reject_imported_evidence(str(report))


class CandidateTests(unittest.TestCase):
    def test_dirty_untracked_deleted_and_index_changes_are_bound(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / "tracked.dart"
            file.write_bytes(b"first")
            listing = b"tracked.dart\0"
            stage = b"100644 blob 0\ttracked.dart\0"

            def fake_git(_, *args):
                if args[0] == "rev-parse":
                    return b"abc123"
                if "--stage" in args:
                    return stage
                return listing

            with patch.object(acceptance, "git", side_effect=fake_git):
                snapshots = [acceptance.candidate(root)]
                file.write_bytes(b"second")
                snapshots.append(acceptance.candidate(root))
                extra = root / "new.dart"
                extra.write_bytes(b"untracked")
                listing += b"new.dart\0"
                snapshots.append(acceptance.candidate(root))
                file.unlink()
                snapshots.append(acceptance.candidate(root))
                stage = b"100755 blob 0\ttracked.dart\0"
                snapshots.append(acceptance.candidate(root))
            self.assertEqual(len({value["worktree_sha256"] for value in snapshots}), len(snapshots))
            for value in snapshots[1:]:
                with self.assertRaises(acceptance.VerificationError):
                    acceptance.require_same_candidate(snapshots[0], value)
            acceptance.require_same_candidate(snapshots[0], snapshots[0])

    def test_all_declared_sources_exist(self):
        for _, paths in acceptance.COMMANDS:
            for path in paths:
                self.assertTrue((acceptance.ROOT / path).exists(), path)


if __name__ == "__main__":
    unittest.main()
