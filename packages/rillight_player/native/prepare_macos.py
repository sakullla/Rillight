"""Stage a hash-verified universal owned-core SDK for the macOS CocoaPod.

No live binary downloads or libmpv fallback are permitted. The target Mac must
provide a pinned FFmpeg/libass/dav1d SDK marker and a separately hashed core dylib.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from verify_core_dependencies import verify

ROOT = Path(__file__).resolve().parent.parent
SPEC = ROOT / "native/core_dependencies.json"
REQUIRED = ("avformat", "avcodec", "avutil", "avfilter", "swresample",
            "swscale", "ass", "dav1d")
RECORD = "rillight-macos-closure.json"
ENV_PREFIX = "RILLIGHT_MACOS_CORE_PREFIX"
ENV_CORE = "RILLIGHT_MACOS_CORE_DYLIB"
ENV_HASH = "RILLIGHT_MACOS_CORE_SHA256"


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def runtime_paths(prefix: Path, marker: dict) -> list[Path]:
    libraries = marker.get("libraries")
    libass = marker.get("libass")
    if not isinstance(libraries, dict) or not isinstance(libass, dict):
        raise RuntimeError("macOS SDK manifest lacks FFmpeg/libass provenance")
    relatives = set(libraries)
    relatives.add(libass.get("library"))
    if None in relatives:
        raise RuntimeError("macOS SDK manifest has no libass library")
    selected = []
    for relative in sorted(relatives):
        if not isinstance(relative, str):
            raise RuntimeError("macOS SDK manifest contains a non-path library")
        if not relative.endswith(".dylib"):
            continue  # Hashed import/static archives are not runtime code.
        source = (prefix / relative).resolve()
        if prefix not in source.parents or not source.is_file():
            raise RuntimeError(f"Missing/unsafe runtime dylib: {relative}")
        selected.append(source)
    names = [path.name for path in selected]
    if len(names) != len(set(names)):
        raise RuntimeError("macOS SDK contains duplicate runtime dylib names")
    for component in REQUIRED:
        if not any(name.startswith(f"lib{component}.") for name in names):
            raise RuntimeError(f"macOS SDK lacks runtime lib{component}.dylib")
    if any("mpv" in name.lower() for name in names):
        raise RuntimeError("macOS SDK contains libmpv")
    return selected


def architectures(path: Path) -> set[str]:
    return set(subprocess.check_output(
        ["lipo", "-archs", str(path)], text=True).split())


def prepare(prefix: Path | None = None, core: Path | None = None,
            expected_core_hash: str | None = None, root: Path = ROOT) -> dict:
    prefix = prefix or (Path(os.environ[ENV_PREFIX]) if os.environ.get(ENV_PREFIX) else None)
    core = core or (Path(os.environ[ENV_CORE]) if os.environ.get(ENV_CORE) else None)
    expected_core_hash = expected_core_hash or os.environ.get(ENV_HASH)
    if prefix is None or core is None or not expected_core_hash:
        raise RuntimeError(f"Set {ENV_PREFIX}, {ENV_CORE}, and {ENV_HASH} to verified macOS core inputs")
    prefix = prefix.resolve()
    core = core.resolve()
    root = root.resolve()
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected_core_hash):
        raise RuntimeError("macOS core SHA256 must be a 64-character hex digest")
    if core.name != "librillight_core.dylib" or not core.is_file():
        raise RuntimeError("Missing owned librillight_core.dylib")
    failures = verify(prefix, "macos-universal", require_subtitles=True)
    if failures:
        raise RuntimeError("macOS SDK verification failed: " + "; ".join(failures))
    if digest(core).lower() != expected_core_hash.lower():
        raise RuntimeError("Owned core dylib SHA256 mismatch")
    marker_path = prefix / "rillight-core-dependencies.json"
    marker = json.loads(marker_path.read_text(encoding="utf-8"))
    sources = runtime_paths(prefix, marker) + [core]
    if len({path.name for path in sources}) != len(sources):
        raise RuntimeError("Core and SDK dylib names collide")
    for source in sources:
        if not {"x86_64", "arm64"}.issubset(architectures(source)):
            raise RuntimeError(f"macOS native dylib is not universal: {source.name}")
    header = (root / "native/core/rillight_core.h").read_text(encoding="utf-8")
    abi = re.search(r"#define RILLIGHT_CORE_ABI_VERSION\s+(\d+)", header)
    if abi is None:
        raise RuntimeError("Owned core ABI declaration missing")
    record = {
        "schema": 1,
        "target": "macos-universal",
        "core_abi": int(abi.group(1)),
        "ffmpeg_version": marker["ffmpeg_version"],
        "ffmpeg_commit": marker["ffmpeg_commit"],
        "ffmpeg_tag": marker["ffmpeg_tag"],
        "ffmpeg_patches": marker["ffmpeg_patches"],
        "libass_version": marker["libass"]["version"],
        "libass_commit": marker["libass"]["commit"],
        "sdk_marker_sha256": digest(marker_path),
        "core_spec_sha256": digest(root / "native/core_dependencies.json"),
        "libraries": {path.name: digest(path) for path in sources},
    }
    destination = root / "macos/Libraries"
    destination.mkdir(parents=True, exist_ok=True)
    for source in sources:
        target = destination / source.name
        shutil.copyfile(source, target)
        if digest(target) != record["libraries"][source.name]:
            raise RuntimeError(f"Staged macOS dylib hash mismatch: {source.name}")
    for stale in destination.glob("*.dylib"):
        if stale.name not in record["libraries"]:
            stale.unlink()
    (destination / RECORD).write_text(
        json.dumps(record, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8")
    return record


if __name__ == "__main__":
    prepared = prepare()
    print("Prepared owned macOS core closure:", len(prepared["libraries"]),
          "universal dylibs")
