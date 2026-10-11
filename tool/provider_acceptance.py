#!/usr/bin/env python3
"""Run candidate-bound synthetic provider acceptance; never trust imported passes.

The trust boundary is this invocation's child process, not a JSON success flag,
an unsigned log, or a local hash. Output is diagnostic evidence under build/.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = "rillight-provider-acceptance-v1"
LOOP_SUITE = "test/provider_acceptance/provider_acceptance_test.dart"
REQUIRED = {
    "acceptance emby login catalog playback stop logout resume",
    "acceptance emby rejects credentials and revoked session",
    "acceptance jellyfin login catalog playback stop logout resume",
    "acceptance jellyfin rejects password cancellation and forbidden playback",
    "acceptance plex login catalog playback stop logout resume",
    "acceptance plex rejects Home PIN shared revocation and transcode",
    "acceptance plex discovers owned and shared without granting Home ownership",
}
COMMANDS = (
    ("protocol", (LOOP_SUITE, "test/jellyfin", "test/plex")),
    ("boundaries", (
        "test/auth/provider_identity_test.dart",
        "test/auth/source_sessions_test.dart",
        "test/aggregation/access_boundary_test.dart",
        "test/aggregation/history_test.dart",
        "test/aggregation/playback_switch_test.dart",
        "test/player/provider_process_boundary_test.dart",
    )),
    ("product", (
        "test/auth/provider_connect_controller_test.dart",
        "test/auth/provider_connect_dialog_test.dart",
        "test/auth/provider_connect_management_test.dart",
        "test/auth/provider_connect_routing_test.dart",
        "test/auth/provider_selection_test.dart",
        "test/auth/provider_line_boundaries_test.dart",
        "test/catalog/catalog_browse_cases.dart",
        "test/catalog/catalog_controller_cases.dart",
        "test/catalog/filter_panel_test.dart",
        "test/catalog/library_filter_cases.dart",
        "test/home/library_latest_row_test.dart",
    )),
)
PLATFORMS = ("windows", "macos", "linux", "android-phone", "android-tv")
FIXTURES = {
    "emby": ("test/emby/fake_emby_server.dart", "Emby synthetic 4.8.0.0 route fixture"),
    "jellyfin": ("test/jellyfin/fake_jellyfin_server.dart", "frozen OpenAPI 12.2.0; see test/jellyfin/protocol_contract.json"),
    "plex": ("test/plex/fake_plex.dart", "PMS OpenAPI 1.2.3; synthetic fixture v2 + token-scoped timeline"),
}


class VerificationError(Exception):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(root: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.PIPE)


def candidate(root: Path) -> dict:
    """Bind tracked and nonignored untracked bytes, including deletions and mode.

    HEAD alone is insufficient in a dirty working tree. Generated evidence is
    required to be ignored so it cannot change the candidate being measured.
    """
    head = git(root, "rev-parse", "HEAD").decode().strip()
    names = sorted(set(git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0")) - {b""})
    hashed = hashlib.sha256()
    for name in names:
        path = root / os.fsdecode(name)
        if path.is_symlink():
            kind, content = b"symlink", os.fsencode(os.readlink(path))
        elif path.is_file():
            kind, content = b"file", path.read_bytes()
        elif not path.exists():
            kind, content = b"deleted", b""
        else:
            raise VerificationError(f"Cannot bind repository entry: {os.fsdecode(name)}")
        hashed.update(name + b"\0" + kind + b"\0" + hashlib.sha256(content).digest())
    # Index records also bind executable modes and staged deletions.
    hashed.update(git(root, "ls-files", "--stage", "-z"))
    return {"head": head, "worktree_sha256": hashed.hexdigest(), "input_count": len(names)}


def require_same_candidate(before: dict, after: dict) -> None:
    if before != after:
        raise VerificationError("Candidate changed during execution; rerun after edits stop")


def inspect_machine_log(raw: str, required: set[str] = frozenset()) -> dict:
    tests, completed, suites = {}, {}, {}
    done = None
    for line in raw.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue  # Flutter may print SDK setup notices before JSON events.
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        if kind == "suite":
            suite = event["suite"]
            suites[suite["id"]] = suite["path"].replace("\\", "/")
        elif kind == "testStart":
            test = event["test"]
            if test["id"] in tests:
                raise VerificationError("Duplicate test start")
            tests[test["id"]] = test
        elif kind == "testDone":
            identity = event["testID"]
            if identity not in tests or identity in completed:
                raise VerificationError("Missing or duplicate test execution identity")
            if event.get("result") != "success" or event.get("skipped"):
                raise VerificationError(f"Failed/skipped test: {tests[identity]['name']}")
            completed[identity] = event
        elif kind == "error":
            raise VerificationError("Flutter reported a test error; inspect the raw log")
        elif kind == "done":
            if done is not None:
                raise VerificationError("Duplicate final test result")
            done = event
    if done is None or done.get("success") is not True:
        raise VerificationError("Missing successful runner completion")
    if tests.keys() != completed.keys():
        raise VerificationError("Incomplete test run")
    visible = [tests[key] for key, result in completed.items() if not result.get("hidden", False)]
    if not visible:
        raise VerificationError("No executed tests")
    names = {test["name"] for test in visible}
    if required - names:
        raise VerificationError("Missing required scenarios: " + ", ".join(sorted(required - names)))
    for test in visible:
        if test.get("suiteID") not in suites:
            raise VerificationError("Test has no source suite")
        if test["name"] in required and not suites[test["suiteID"]].endswith("/" + LOOP_SUITE):
            raise VerificationError("Required scenario came from another suite")
    return {"passed": len(visible), "scenarios": sorted(names), "suites": sorted(set(suites.values()))}


def reject_imported_evidence(path: str) -> None:
    # Hashes detect accidental edits, not authorship. Even a perfectly formed
    # imported manifest can be fabricated. Only a fresh child execution counts.
    raise VerificationError(
        f"Imported evidence is not trusted ({path}); run --verify without --evidence. "
        "Old, incomplete, candidate-mismatched and fabricated reports cannot substitute for execution."
    )


def run(root: Path = ROOT) -> Path:
    flutter = shutil.which("flutter")
    if flutter is None:
        raise VerificationError("Flutter is unavailable; synthetic acceptance is unverified")
    for _, paths in COMMANDS:
        for path in paths:
            if not (root / path).exists():
                raise VerificationError(f"Missing required scenario source: {path}")
    output_root = root / "build/provider-acceptance"
    output_root.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="run-", dir=output_root))
    ignored = subprocess.run(["git", "-C", str(root), "check-ignore", "--quiet", str(output / "result.json")])
    if ignored.returncode != 0:
        raise VerificationError("Acceptance output must be ignored by Git")
    before = candidate(root)
    report = {
        "schema": SCHEMA,
        "candidate": before,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "host": sys.platform,
        "status": "failed",
        "evidence_level": "synthetic-protocol",
        "fixtures": {
            name: {"path": path, "sha256": digest((root / path).read_bytes()), "simulated_baseline": baseline,
                   "actual_service_version": None}
            for name, (path, baseline) in FIXTURES.items()
        },
        "commands": [],
        "platform_matrix": [
            {"provider": provider, "platform": platform, "candidate": before,
             "sample": None, "evidence": None, "status": "unverified",
             "real_service": "unverified", "real_transcode_cleanup": "unverified",
             "native_install_launch": "unverified", "displayed_frames": "unverified",
             "physical_audio": "unverified", "hardware_stability": "unverified"}
            for provider in FIXTURES for platform in PLATFORMS
        ],
    }
    print(f"Synthetic evidence: {output}", flush=True)
    try:
        version = subprocess.run([flutter, "--version", "--machine"], cwd=root, capture_output=True, timeout=120)
        (output / "flutter-version.log").write_bytes(version.stdout + version.stderr)
        if version.returncode:
            raise VerificationError("Cannot read Flutter version")
        report["flutter_version_sha256"] = digest(version.stdout + version.stderr)
        for label, paths in COMMANDS:
            command = [flutter, "test", "--no-pub", "--concurrency=1", "--reporter=json", *paths]
            print(f"Running {label} synthetic tests...", flush=True)
            log = output / f"{label}.jsonl"
            record = {"command": command, "log": log.name, "status": "failed"}
            report["commands"].append(record)
            with log.open("wb") as stream:
                process = subprocess.run(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT, timeout=1200)
            raw = log.read_bytes()
            record.update(returncode=process.returncode, sha256=digest(raw))
            if process.returncode:
                raise VerificationError(f"{label} failed (exit {process.returncode}); see {log}")
            record.update(inspect_machine_log(raw.decode("utf-8", errors="replace"), REQUIRED if label == "protocol" else set()))
            require_same_candidate(before, candidate(root))
            record["status"] = "passed"
        report["status"] = "passed"
    except (VerificationError, subprocess.TimeoutExpired, OSError) as error:
        report["failure"] = str(error)
        raise VerificationError(str(error)) from error
    finally:
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        (output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("PASS: current candidate synthetic protocol, boundary and product tests. All 15 real platform combinations remain unverified.", flush=True)
    return output


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true", required=True, help="execute fresh candidate-bound tests")
    parser.add_argument("--evidence", help="imported results are explicitly rejected; rerun instead")
    args = parser.parse_args(argv)
    try:
        if args.evidence is not None:
            reject_imported_evidence(args.evidence)
        run()
    except (VerificationError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
