"""Measure the three Flutter test commands, including startup and compilation."""

import argparse
from datetime import datetime
import json
import platform
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
MODES = {
    "fast": (20, ["--exclude-tags", "integration"]),
    "full": (20, []),
    "integration": (15, ["--tags", "integration"]),
}


def inspect_log(path):
    starts, completed, suites, timings = {}, {}, {}, []
    suite_timings = {}
    errors, done = [], None
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        kind = event.get("type")
        if kind == "suite":
            suites[event["suite"]["id"]] = event["suite"]["path"]
        elif kind == "testStart":
            starts[event["test"]["id"]] = (event["time"], event["test"])
        elif kind == "testDone":
            completed[event["testID"]] = event
        elif kind == "error":
            errors.append(event.get("error"))
        elif kind == "done":
            done = event
    visible, skipped = [], []
    for identity, result in completed.items():
        if identity not in starts:
            errors.append("Completion without a test start")
            continue
        started, test = starts[identity]
        if result.get("hidden"):
            continue
        if result.get("skipped"):
            skipped.append(test["name"])
            continue
        if result.get("result") != "success":
            errors.append("Failed: " + test["name"])
        visible.append(test["name"])
        timings.append({"name": test["name"], "seconds": (result["time"] - started) / 1000})
        suite = suites.get(test["suiteID"], str(test["suiteID"]))
        suite_timings[suite] = suite_timings.get(suite, 0) + (result["time"] - started) / 1000
    return {
        "success": bool(done and done.get("success") and visible and not errors
                        and starts.keys() == completed.keys()),
        "tests": len(visible),
        "skipped": skipped,
        "errors": errors,
        "suites": len(suites),
        "slowest": sorted(timings, key=lambda item: -item["seconds"])[:15],
        "suite_test_seconds": dict(sorted(suite_timings.items(), key=lambda item: -item[1])),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["all", *MODES], default="all")
    parser.add_argument("--repeat", type=int, default=1)
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be positive")
    flutter = shutil.which("flutter")
    if flutter is None:
        parser.error("flutter is not on PATH")
    out = ROOT / "build/test-timing" / datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    out.mkdir(parents=True)
    report = {"host": platform.platform(), "timing": "command startup through process exit", "runs": []}
    modes = MODES if args.mode == "all" else [args.mode]
    for repeat in range(args.repeat):
        for mode in modes:
            limit, flags = MODES[mode]
            command = [flutter, "test", *flags, "--reporter", "json"]
            log = out / f"{mode}-{repeat + 1}.jsonl"
            started = time.perf_counter()
            with log.open("w", encoding="utf-8") as output:
                result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
            elapsed = time.perf_counter() - started
            run = inspect_log(log)
            run.update(mode=mode, seconds=round(elapsed, 3), limit=limit,
                       within_budget=elapsed < limit, exit_code=result.returncode,
                       command=command, log=str(log.relative_to(ROOT)))
            report["runs"].append(run)
            print(f"{mode}: {elapsed:.3f}s / {limit}s; {run['tests']} tests; "
                  f"tests={'PASS' if run['success'] and result.returncode == 0 else 'FAIL'}; "
                  f"budget={'PASS' if run['within_budget'] else 'FAIL'}", flush=True)
    summary = out / "summary.json"
    summary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(summary.relative_to(ROOT))
    return 0 if all(r["success"] and r["exit_code"] == 0 and r["within_budget"] for r in report["runs"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
