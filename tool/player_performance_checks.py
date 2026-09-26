"""Compare measured baseline and candidate runs from identical device scenarios.

Input is one JSON object per attempted run. Failed/time-out runs remain in the
sample count. The CLI deliberately fails when required real measurements are
absent; a configured benchmark is not a measured improvement.
"""

import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re
import statistics
import sys


ROOT = Path(__file__).resolve().parents[1]
TARGETS = ("windows", "macos", "linux", "android-phone", "android-tv")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
CATEGORIES = ("page", "network", "animation")
METRIC = {"page": "firstOperableMs", "network": "stallMs",
          "animation": "overBudgetRate"}
KEY = ("target", "category", "label", "cache", "device", "buildMode",
       "media", "network", "quality", "frameBudgetMs")


def percentile(values: list[float], fraction: float) -> float:
    values = sorted(values)
    point = (len(values) - 1) * fraction
    low = int(point)
    return values[low] + (values[min(low + 1, len(values) - 1)] - values[low]) * (point - low)


def summarize(rows: list[dict], metric: str) -> dict:
    measured = [float(row[metric]) for row in rows
                if row.get("complete") is True and isinstance(row.get(metric), (int, float))
                and not isinstance(row.get(metric), bool) and row[metric] >= 0]
    result = {"attempts": len(rows), "failures": len(rows) - len(measured),
              "measured": len(measured)}
    if measured:
        result.update({"median": statistics.median(measured),
                       "p05": percentile(measured, 0.05),
                       "p95": percentile(measured, 0.95),
                       "min": min(measured), "max": max(measured)})
    return result


def load_rows(path: Path, expected_phase: str) -> tuple[dict[tuple, list[dict]], list[str]]:
    groups = defaultdict(list)
    errors = []
    artifacts = {}
    if not path.is_file():
        return groups, [f"{expected_phase}: missing sample file {path}"]
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except ValueError as error:
            errors.append(f"{expected_phase}:{number}: invalid JSON: {error}")
            continue
        if not isinstance(row, dict):
            errors.append(f"{expected_phase}:{number}: expected object")
            continue
        if row.get("phase") != expected_phase:
            errors.append(f"{expected_phase}:{number}: phase mismatch")
            continue
        if any(row.get(field) is None or row.get(field) == "" for field in KEY):
            errors.append(f"{expected_phase}:{number}: missing scenario identity")
            continue
        if (row["target"] not in TARGETS or row["category"] not in CATEGORIES or
                row["cache"] not in ("cold", "warm") or
                row["buildMode"] not in ("profile", "release") or
                not isinstance(row["frameBudgetMs"], (int, float)) or
                row["frameBudgetMs"] <= 0):
            errors.append(f"{expected_phase}:{number}: invalid target, mode or frame budget")
            continue
        if (not isinstance(row.get("artifactSha256"), str) or
                not SHA256.fullmatch(row["artifactSha256"].lower())):
            errors.append(f"{expected_phase}:{number}: missing artifact identity")
            continue
        if not isinstance(row.get("artifactPath"), str) or not row["artifactPath"]:
            errors.append(f"{expected_phase}:{number}: missing candidate artifact path")
            continue
        artifact = Path(row["artifactPath"])
        if not artifact.is_absolute():
            artifact = path.parent / artifact
        if not artifact.is_file():
            errors.append(f"{expected_phase}:{number}: artifact does not exist")
            continue
        if artifact not in artifacts:
            digest = hashlib.sha256()
            with artifact.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            artifacts[artifact] = digest.hexdigest()
        if artifacts[artifact] != row["artifactSha256"].lower():
            errors.append(f"{expected_phase}:{number}: artifact hash mismatch")
            continue
        if row["category"] == "animation":
            ui, raster = row.get("uiFrameMs"), row.get("rasterFrameMs")
            if (row.get("frameTimingsComplete") is not True or
                    not isinstance(row.get("elapsedMs"), (int, float)) or
                    row["elapsedMs"] < 60000 or
                    not isinstance(ui, list) or not isinstance(raster, list) or
                    not ui or len(ui) != len(raster) or
                    any(not isinstance(value, (int, float)) or value < 0
                        for value in ui + raster)):
                row["complete"] = False
            else:
                budget = row["frameBudgetMs"]
                row["overBudgetRate"] = sum(
                    x > budget or y > budget for x, y in zip(ui, raster)
                ) / len(ui)
        groups[tuple(row[field] for field in KEY)].append(row)
    if not groups:
        errors.append(f"{expected_phase}: no valid measured scenarios")
    return groups, errors


def compare(baseline: dict[tuple, list[dict]], candidate: dict[tuple, list[dict]],
            *, targets: tuple[str, ...], minimum: int = 20) -> tuple[list[dict], list[str]]:
    results = []
    errors = []
    keys = {key for key in baseline if key[0] in targets} | {key for key in candidate if key[0] in targets}
    for target in targets:
        for category in CATEGORIES:
            if not any(key[0] == target and key[1] == category for key in keys):
                errors.append(f"{target}/{category}: missing baseline and candidate runs")
    improvements = defaultdict(int)
    for key in sorted(keys):
        name = "/".join(str(item) for item in key[:4])
        before = baseline.get(key, [])
        after = candidate.get(key, [])
        metric = METRIC[key[1]]
        first = summarize(before, metric)
        second = summarize(after, metric)
        row = {"scenario": name, "metric": metric,
               "baseline": first, "candidate": second, "verdict": "unknown"}
        results.append(row)
        if len(before) < minimum or len(after) < minimum:
            errors.append(f"{name}: requires {minimum} attempts in each phase")
            continue
        if first["measured"] == 0 or second["measured"] == 0:
            errors.append(f"{name}: no successful metric samples")
            continue
        if second["failures"] > first["failures"]:
            errors.append(f"{name}: candidate has more failed or timed-out runs")
            continue
        # Baseline spread is the noise floor; a single fast candidate sample
        # cannot establish an improvement. Preserve all outliers in the report.
        spread = first["p95"] - first["p05"]
        tolerance = max(0.001, spread)
        if second["median"] > first["median"] + tolerance:
            row["verdict"] = "regressed"
            errors.append(f"{name}: median regression exceeds baseline variation")
        elif second["median"] < first["median"] - tolerance:
            row["verdict"] = "improved"
            improvements[(key[0], key[1])] += 1
        else:
            row["verdict"] = "indistinguishable"
    for target in targets:
        for category in CATEGORIES:
            if improvements[(target, category)] == 0:
                errors.append(f"{target}/{category}: no improvement beyond baseline variation")
    return results, errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path,
                        default=ROOT / "build/player-performance/baseline.jsonl")
    parser.add_argument("--candidate", type=Path,
                        default=ROOT / "build/player-performance/candidate.jsonl")
    parser.add_argument("--compare-baseline", action="store_true")
    parser.add_argument("--require-all-targets", action="store_true")
    parser.add_argument("--target", choices=TARGETS, action="append")
    parser.add_argument("--macos-handoff", type=Path)
    parser.add_argument("--minimum-samples", type=int, default=20)
    args = parser.parse_args(argv)
    if not args.compare_baseline or (not args.require_all_targets and not args.target):
        parser.error("use --compare-baseline with --require-all-targets or --target")
    if args.minimum_samples < 1:
        parser.error("minimum samples must be positive")
    targets = list(TARGETS if args.require_all_targets else dict.fromkeys(args.target))
    unverified = []
    errors = []
    baseline, baseline_errors = load_rows(args.baseline, "baseline")
    candidate, candidate_errors = load_rows(args.candidate, "candidate")
    errors.extend(baseline_errors + candidate_errors)
    macos_measured = any(key[0] == "macos" for key in baseline) or any(
        key[0] == "macos" for key in candidate)
    if "macos" in targets and args.macos_handoff is not None and not macos_measured:
        if args.macos_handoff.is_file():
            targets.remove("macos")
            unverified.append("macos: performance comparison pending target machine")
        else:
            errors.append(f"macos: missing handoff {args.macos_handoff}")
    results, comparison_errors = compare(
        baseline, candidate, targets=tuple(targets), minimum=args.minimum_samples)
    errors.extend(comparison_errors)
    print(json.dumps({"passed": not errors and not unverified,
                      "accepted_with_handoff": not errors and bool(unverified),
                      "unverified": unverified, "errors": errors,
                      "comparisons": results}, ensure_ascii=False, indent=2))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
