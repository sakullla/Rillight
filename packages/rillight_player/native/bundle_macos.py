"""Bundle the verified owned-core macOS dylib closure before app signing.

Usage: python3 bundle_macos.py path/to/rillight.app
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from prepare_macos import RECORD, ROOT, digest, prepare


def otool_dependencies(output: str) -> list[str]:
    # Thin and fat Mach-O output contains title lines. Only load/id records
    # include a compatibility-version field; retain all architecture slices.
    return [line.strip().split(" (", 1)[0] for line in output.splitlines()
            if " (compatibility version " in line]


def audit_binary(binary: Path, contents: Path) -> None:
    frameworks = contents / "Frameworks"
    output = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    for dependency in otool_dependencies(output):
        if "mpv" in dependency.lower():
            raise RuntimeError(f"Legacy playback dependency: {dependency}")
        if dependency.startswith("@rpath/"):
            target = frameworks / dependency.removeprefix("@rpath/")
        elif dependency.startswith("@loader_path/"):
            target = binary.parent / dependency.removeprefix("@loader_path/")
        elif dependency.startswith("@executable_path/"):
            target = contents / "MacOS" / dependency.removeprefix("@executable_path/")
        elif dependency.startswith(("/System/Library/", "/usr/lib/")):
            continue
        else:
            raise RuntimeError(f"Nonportable Mach-O dependency: {dependency}")
        if contents.resolve() not in target.resolve().parents or not target.exists():
            raise RuntimeError(f"{binary.name}: unbundled dependency {dependency}")


def bundle(app_path: Path, *, root: Path = ROOT, record: dict | None = None) -> dict:
    # Reverify immediately before copying: a stale CocoaPods staging directory
    # must not silently become a release input after the SDK changes.
    record = record or prepare(root=root)
    app = Path(app_path).resolve()
    root = root.resolve()
    if app.suffix != ".app" or not (app / "Contents/MacOS").is_dir():
        raise RuntimeError("Expected an existing macOS .app with an executable directory")
    contents = app / "Contents"
    destination = contents / "Frameworks"
    destination.mkdir(exist_ok=True)
    if any("mpv" in path.name.lower() for path in destination.glob("*.dylib")):
        raise RuntimeError("Application still contains a libmpv dylib")
    staged = root / "macos/Libraries"
    names = set(record["libraries"])
    if "librillight_core.dylib" not in names:
        raise RuntimeError("Owned core is absent from macOS closure")
    for name, expected in record["libraries"].items():
        source = staged / name
        if not source.is_file() or digest(source) != expected:
            raise RuntimeError(f"Staged native dylib hash mismatch: {name}")
        target = destination / name
        shutil.copyfile(source, target)
        if digest(target) != expected:
            raise RuntimeError(f"Bundled native dylib hash mismatch: {name}")
    for name in names:
        audit_binary(destination / name, contents)
    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY", "") or "-"
    for name in sorted(names):
        subprocess.check_call(["codesign", "--force", "--sign", identity,
                               "--timestamp=none", str(destination / name)])
    record = dict(record)
    record["bundled_libraries_sha256"] = {
        name: digest(destination / name) for name in sorted(names)}
    resources = contents / "Resources"
    resources.mkdir(exist_ok=True)
    (resources / RECORD).write_text(
        json.dumps(record, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8")
    shutil.copyfile(root / "native/core_dependencies.json",
                    resources / "rillight-core-source-lock.json")
    sdk_marker = Path(os.environ["RILLIGHT_MACOS_CORE_PREFIX"]) / \
        "rillight-core-dependencies.json"
    if digest(sdk_marker) != record["sdk_marker_sha256"]:
        raise RuntimeError("macOS SDK marker changed during packaging")
    shutil.copyfile(sdk_marker, resources / "rillight-core-dependencies.json")
    notices = root / "THIRD_PARTY_NOTICES.md"
    if not notices.is_file():
        raise RuntimeError("Native third-party notices are missing")
    shutil.copyfile(notices, resources / "rillight-native-notices.md")
    for name in ("FFmpeg-GPL-2.0.txt", "FFmpeg-LGPL-2.1.txt", "libass-ISC.txt",
                 "dav1d-BSD-2-Clause.txt"):
        source = root / "native/licenses" / name
        if not source.is_file():
            raise RuntimeError(f"Native license material missing: {name}")
        target = resources / "rillight-native-licenses" / name
        target.parent.mkdir(exist_ok=True)
        shutil.copyfile(source, target)
    print("Bundled and signed", len(names), "verified universal core dylibs")
    return record


if __name__ == "__main__":
    bundle(Path(sys.argv[1]))
