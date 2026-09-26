"""Check pinned source metadata and library bytes of the development C SDK.

This check does not establish a distributable package. In particular, the
libass 0.17.5 Meson build warns that non-Windows shared libraries lack proper
symbol visibility for distribution. It also does not audit transitive runtime
libraries, ELF RUNPATH, licenses, or target-device playback.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import sys


ROOT = Path(__file__).resolve().parent
SPEC = json.loads((ROOT / "core_dependencies.json").read_text(encoding="utf-8"))


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def verify(prefix: Path, target: str, require_subtitles: bool = False) -> list[str]:
    errors: list[str] = []
    marker_file = prefix / "rillight-core-dependencies.json"
    if not marker_file.is_file():
        return [f"{target}: missing {marker_file}"]
    try:
        marker = json.loads(marker_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return [f"{target}: invalid manifest: {error}"]
    if marker.get("platform") != target:
        errors.append(f"{target}: manifest platform mismatch")
    if marker.get("ffmpeg_version") != SPEC["ffmpeg"]["version"]:
        errors.append(f"{target}: FFmpeg version mismatch")
    if marker.get("ffmpeg_commit") != SPEC["ffmpeg"]["commit"]:
        errors.append(f"{target}: FFmpeg source commit mismatch")
    if marker.get("ffmpeg_tag") != SPEC["ffmpeg"]["version"]:
        errors.append(f"{target}: FFmpeg release tag mismatch")
    patches = SPEC["ffmpeg"].get("patches", {})
    if marker.get("ffmpeg_patches") != patches:
        errors.append(f"{target}: FFmpeg patch provenance mismatch")
    for relative, expected in patches.items():
        path = (ROOT / relative).resolve()
        if ROOT.resolve() not in path.parents or not path.is_file() or \
                digest(path).lower() != expected.lower():
            errors.append(f"{target}: FFmpeg patch hash mismatch {relative}")
    if target == "linux-x64":
        configure = marker.get("configure")
        if not isinstance(configure, list) or not {"--enable-vaapi", "--enable-libdrm"} <= set(configure):
            errors.append(f"{target}: VAAPI/DRM were not enabled in FFmpeg")
        build_dependencies = marker.get("vaapi_build_dependencies")
        if not isinstance(build_dependencies, dict) or any(
                not isinstance(build_dependencies.get(name), str)
                for name in ("libva", "libva-drm", "libdrm")):
            errors.append(f"{target}: missing VAAPI build dependency provenance")
    libraries = marker.get("libraries")
    if not isinstance(libraries, dict) or not libraries:
        errors.append(f"{target}: missing library hashes")
    else:
        for name in SPEC["ffmpeg"]["libraries"]:
            if not any(Path(path).name.startswith((f"lib{name}.", f"{name}.")) for path in libraries):
                errors.append(f"{target}: missing {name}")
        for relative, expected in libraries.items():
            path = (prefix / relative).resolve()
            if prefix.resolve() not in path.parents or not path.is_file():
                errors.append(f"{target}: missing/unsafe library {relative}")
            elif digest(path).lower() != str(expected).lower():
                errors.append(f"{target}: SHA256 mismatch {relative}")
    for header in ("libavformat/avformat.h", "libavcodec/avcodec.h",
                   "libavutil/avutil.h", "libswresample/swresample.h",
                   "libswscale/swscale.h", "libavfilter/avfilter.h"):
        if not (prefix / "include" / header).is_file():
            errors.append(f"{target}: missing header {header}")
    libass = marker.get("libass")
    if require_subtitles and not isinstance(libass, dict):
        errors.append(f"{target}: missing pinned libass for ASS/SSA")
    if isinstance(libass, dict):
        specification = SPEC["libass"]
        if libass.get("version") != specification["version"] or \
                libass.get("commit") != specification["commit"]:
            errors.append(f"{target}: libass version/source mismatch")
        relative = libass.get("library")
        if not isinstance(relative, str):
            errors.append(f"{target}: missing libass library path")
        else:
            path = (prefix / relative).resolve()
            if prefix.resolve() not in path.parents or not path.is_file():
                errors.append(f"{target}: missing/unsafe libass library {relative}")
            elif digest(path).lower() != str(libass.get("sha256", "")).lower():
                errors.append(f"{target}: libass SHA256 mismatch {relative}")
        if not (prefix / "include" / "ass" / "ass.h").is_file():
            errors.append(f"{target}: missing libass header")
        build_dependencies = libass.get("build_dependencies", {})
        for name in specification["required_build_dependencies"]:
            if not isinstance(build_dependencies.get(name), str):
                errors.append(f"{target}: missing {name} build provenance")
        if target.startswith("android-"):
            if libass.get("android_sources") != specification.get("android_sources"):
                errors.append(f"{target}: Android subtitle source pins mismatch")
            if build_dependencies.get("fontconfig") != "disabled (Android explicit font path)":
                errors.append(f"{target}: Android font provider provenance mismatch")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path)
    parser.add_argument("--target", choices=SPEC["platforms"])
    parser.add_argument("--all-platforms", action="store_true")
    parser.add_argument("--require-subtitles", action="store_true")
    args = parser.parse_args()
    if args.all_platforms:
        targets = list(SPEC["platforms"])
    else:
        native = {"Windows": "windows-x64", "Darwin": "macos-universal",
                  "Linux": "linux-x64"}.get(platform.system())
        targets = [args.target or native]
    if None in targets:
        parser.error("specify --target for this host")
    failures: list[str] = []
    for target in targets:
        env_name = "RILLIGHT_CORE_PREFIX_" + target.upper().replace("-", "_")
        prefix = args.prefix or (Path(os.environ[env_name]) if env_name in os.environ else None)
        if prefix is None:
            failures.append(f"{target}: set {env_name} to the pinned SDK prefix")
        else:
            failures.extend(verify(prefix, target, args.require_subtitles))
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        return 1
    print("Verified FFmpeg SDK: " + ", ".join(targets))
    return 0


if __name__ == "__main__":
    sys.exit(main())
