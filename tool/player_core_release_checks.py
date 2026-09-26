"""Audit candidate-bound playback release evidence without inventing device results.

Each target JSON lives at <evidence-root>/<target>.json. A successful check must
point to a real evidence file. This aggregator never runs a player itself.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
TARGETS = ("windows", "macos", "linux", "android-phone", "android-tv")
REQUIRED = ("native_build", "package_closure", "installed_launch",
            "actual_video", "actual_audio", "av_sync")
HARDWARE = ("actual_video", "actual_audio", "av_sync")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def candidate_revision() -> str:
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True,
    ).strip()


def evidence_path(value: object, evidence_root: Path) -> Path | None:
    if not isinstance(value, str) or not value.strip():
        return None
    path = Path(value)
    return path if path.is_absolute() else evidence_root / path


def audit_target(target: str, evidence_root: Path, revision: str,
                 require_hardware: bool) -> list[str]:
    errors = []
    record_path = evidence_root / f"{target}.json"
    if not record_path.is_file():
        return [f"{target}: missing result {record_path}"]
    try:
        record = json.loads(record_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return [f"{target}: invalid result: {error}"]
    if not isinstance(record, dict) or record.get("schema") != 1:
        return [f"{target}: expected schema 1 object"]
    if record.get("target") != target:
        errors.append(f"{target}: target identity mismatch")
    if record.get("candidate_revision") != revision:
        errors.append(f"{target}: candidate revision mismatch")
    artifact = evidence_path(record.get("artifact"), evidence_root)
    expected = record.get("artifact_sha256")
    if artifact is None or not artifact.is_file():
        errors.append(f"{target}: missing candidate artifact")
    elif not isinstance(expected, str) or not SHA256.fullmatch(expected.lower()):
        errors.append(f"{target}: missing artifact SHA256")
    elif digest(artifact) != expected.lower():
        errors.append(f"{target}: candidate artifact SHA256 mismatch")
    checks = record.get("checks")
    if not isinstance(checks, dict):
        return errors + [f"{target}: missing checks object"]
    for name in REQUIRED:
        check = checks.get(name)
        if not isinstance(check, dict) or check.get("passed") is not True:
            errors.append(f"{target}: {name} not verified")
            continue
        source = evidence_path(check.get("evidence"), evidence_root)
        if source is None or not source.is_file():
            errors.append(f"{target}: {name} has no readable evidence")
        if require_hardware and name in HARDWARE and check.get("environment") != "hardware":
            errors.append(f"{target}: {name} lacks hardware evidence")
    dependencies = record.get("dependencies")
    if not isinstance(dependencies, dict) or not dependencies:
        errors.append(f"{target}: missing native dependency closure")
    else:
        for name, item in dependencies.items():
            if not isinstance(item, dict):
                errors.append(f"{target}: invalid dependency {name}")
                continue
            path = evidence_path(item.get("path"), evidence_root)
            checksum = item.get("sha256")
            if (path is None or not path.is_file() or
                    not isinstance(checksum, str) or
                    not SHA256.fullmatch(checksum.lower()) or
                    digest(path) != checksum.lower()):
                errors.append(f"{target}: unverified dependency {name}")
        if any("mpv" in name.lower() or "media3" in name.lower()
               for name in dependencies):
            errors.append(f"{target}: retired playback dependency recorded")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-root", type=Path,
                        default=ROOT / "build/player-core-release")
    parser.add_argument("--candidate-revision", default=None)
    parser.add_argument("--all-platforms", action="store_true")
    parser.add_argument("--target", choices=TARGETS, action="append")
    parser.add_argument("--require-hardware", action="store_true")
    parser.add_argument("--macos-handoff", type=Path,
                        help="Explicitly report macOS as unverified without blocking local workflow closure")
    args = parser.parse_args(argv)
    if not args.all_platforms and not args.target:
        parser.error("choose --all-platforms or --target")
    selected = TARGETS if args.all_platforms else tuple(dict.fromkeys(args.target))
    revision = args.candidate_revision or candidate_revision()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        parser.error("candidate revision must be a full Git SHA")
    errors = []
    unverified = []
    for target in selected:
        if (target == "macos" and args.macos_handoff is not None and
                not (args.evidence_root / "macos.json").exists()):
            if not args.macos_handoff.is_file():
                errors.append(f"macos: handoff document missing: {args.macos_handoff}")
            else:
                unverified.append("macos: target-machine build, playback and hardware evidence pending")
            continue
        errors.extend(audit_target(target, args.evidence_root, revision,
                                   args.require_hardware))
    result = {"candidate_revision": revision, "targets": selected,
              "passed": not errors and not unverified,
              "accepted_with_handoff": not errors and bool(unverified),
              "unverified": unverified, "errors": errors}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
