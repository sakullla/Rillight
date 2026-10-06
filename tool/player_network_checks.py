"""Compare HEAD and the working tree with real TCP impairment in Docker.

Only disposable containers get NET_ADMIN. Their network is disabled except for
loopback; tc filters only synthetic-origin response packets, never host traffic.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import time


def run(command: list[str], *, log: Path | None = None) -> None:
    print(" ".join(command), flush=True)
    if log:
        with log.open("w", encoding="utf-8") as output:
            subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
    else:
        subprocess.run(command, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", default="HEAD")
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--size-mib", type=int, default=8)
    parser.add_argument("--scenarios", default="netem-latency,netem-loss,netem-loss-high,single-stream-403")
    args = parser.parse_args()
    if args.trials < 1:
        parser.error("trials must be positive")
    root = Path(__file__).resolve().parents[1]
    stamp = str(time.time_ns())
    output = root / "build/player-validation" / f"network-docker-{stamp}"
    output.mkdir(parents=True)
    ref = subprocess.check_output(["git", "rev-parse", "--verify", args.baseline_ref], cwd=root, text=True).strip()
    paths = subprocess.check_output([
        "git", "ls-tree", "-r", "--name-only", ref, "lib/player/cache", "lib/player/playback_http_proxy.dart"
    ], cwd=root, text=True).splitlines()
    candidate_paths = sorted(set(paths) | {
        path.relative_to(root).as_posix()
        for path in (root / "lib/player/cache").glob("*.dart")
    })
    metadata = {"baselineRef": ref, "trials": args.trials, "sizeMiB": args.size_mib,
                "scenarios": args.scenarios.split(",")}
    (output / "manifest.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    (output / "candidate.diff").write_bytes(subprocess.check_output(["git", "diff", "--binary", "HEAD"], cwd=root))
    images = {}
    for label in ("baseline", "candidate"):
        context = output / f"{label}-source"
        context.mkdir()
        for path in (paths if label == "baseline" else candidate_paths):
            target = context / path
            target.parent.mkdir(parents=True, exist_ok=True)
            if label == "baseline":
                target.write_bytes(subprocess.check_output(["git", "show", f"{ref}:{path}"], cwd=root))
            else:
                shutil.copyfile(root / path, target)
        for name in ("pubspec.yaml", "Dockerfile"):
            shutil.copyfile(root / "tool/network_harness" / name, context / name)
        shutil.copyfile(root / "tool/player_network_harness.dart", context / "player_network_harness.dart")
        image = f"rillight-network-{label}:{stamp}"
        # A docker-container buildx driver does not publish into the daemon's
        # image store unless explicitly loaded. Both comparison images must be
        # runnable locally, regardless of the user's selected builder.
        run(["docker", "buildx", "build", "--load", "-t", image, str(context)],
            log=output / f"{label}-build.log")
        images[label] = image
    failures = []
    # Independent processes, alternating order per trial, same image/runtime.
    # A failed baseline remains in the report; never drop failed measurements.
    for trial in range(args.trials):
        for scenario in metadata["scenarios"]:
            for label in (("baseline", "candidate") if trial % 2 == 0 else ("candidate", "baseline")):
                command = ["docker", "run", "--rm", "--network", "none", "--cap-add", "NET_ADMIN",
                           "--mount", f"type=bind,source={output},target=/work/build/player-validation",
                           images[label], "--label", f"{label}-{trial}", "--trials", "1", "--scenario", scenario,
                           "--size-mib", str(args.size_mib)]
                try:
                    run(command, log=output / f"{label}-{trial}-{scenario}.log")
                except subprocess.CalledProcessError:
                    failures.append({"label": label, "trial": trial, "scenario": scenario})
    rows = []
    for report in output.glob("network-*/report.json"):
        rows.extend(json.loads(report.read_text(encoding="utf-8"))["rows"])
    summary = []
    for scenario in metadata["scenarios"]:
        for seek in (False, True):
            for label in ("baseline", "candidate"):
                subset = [row for row in rows if row["profile"] == scenario and row["seek"] == seek
                          and row["label"].startswith(label)]
                item = {"scenario": scenario, "seek": seek, "label": label,
                        "runs": len(subset), "successes": sum(row["success"] for row in subset)}
                for metric in ("firstByteMs", "elapsedMs", "mibPerSecond", "repeatedBytes", "deliveryStallsOver500Ms"):
                    item[metric] = statistics.median(row[metric] for row in subset) if (
                        len(subset) == args.trials and all(row["success"] for row in subset)
                    ) else None
                summary.append(item)
    (output / "summary.json").write_text(json.dumps({"failures": failures, "rows": summary}, indent=2), encoding="utf-8")
    print(f"Evidence: {output}", flush=True)
    if any(failure["label"] == "candidate" for failure in failures):
        raise SystemExit(1)
    if any(row["label"] == "candidate" and row["successes"] != args.trials for row in summary):
        raise SystemExit("Incomplete candidate evidence")


if __name__ == "__main__":
    main()
