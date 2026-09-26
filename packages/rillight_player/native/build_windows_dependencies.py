"""Rebuild pinned Windows FFmpeg with loopback HTTP support using MSYS2 MinGW64.

The source checkout must be the locked commit with the locked HLS custom-IO
patch already applied. The input prefix contains separately pinned libass and
its transitive runtime closure; this command updates FFmpeg in that prefix.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess

from verify_core_dependencies import SPEC, ROOT
from build_core_dependencies import fetch_source


def run(args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--msys-root", type=Path, default=Path("C:/msys64"))
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 2))
    parser.add_argument("--dav1d-source", type=Path)
    parser.add_argument("--dav1d-build", type=Path)
    args = parser.parse_args()
    if platform.system() != "Windows":
        parser.error("the Windows SDK must be built on Windows")
    source, prefix, build, msys = (path.resolve() for path in
                                   (args.source, args.prefix, args.build, args.msys_root))
    dav1d_source = (args.dav1d_source or build.parent / "dav1d-source").resolve()
    dav1d_build = (args.dav1d_build or build.parent / "dav1d-build").resolve()
    if any(a == b or a in b.parents for a, b in ((source, prefix), (source, build),
                                                 (prefix, build), (build, prefix))):
        parser.error("source, prefix and build paths must be separate")
    if run(["git", "-C", str(source), "rev-parse", "HEAD"]) != SPEC["ffmpeg"]["commit"]:
        parser.error("FFmpeg source is not the pinned commit")
    patches = SPEC["ffmpeg"].get("patches", {})
    for relative, expected in patches.items():
        patch = (ROOT / relative).resolve()
        if ROOT not in patch.parents or not patch.is_file() or digest(patch) != expected:
            parser.error(f"Missing/changed pinned patch: {relative}")
        result = subprocess.run(["git", "-C", str(source), "apply", "--reverse",
                                 "--check", str(patch)], capture_output=True)
        if result.returncode:
            parser.error(f"Pinned FFmpeg patch is not applied: {relative}")
    marker_file = prefix / "rillight-core-dependencies.json"
    if not marker_file.is_file():
        parser.error("input prefix needs an existing pinned libass/FFmpeg SDK marker")
    marker = json.loads(marker_file.read_text(encoding="utf-8"))
    if (marker.get("platform") != "windows-x64" or
            marker.get("ffmpeg_commit") != SPEC["ffmpeg"]["commit"] or
            marker.get("ffmpeg_version") != SPEC["ffmpeg"]["version"] or
            marker.get("ffmpeg_patches") != patches or
            marker.get("libass", {}).get("version") != SPEC["libass"]["version"] or
            marker.get("libass", {}).get("commit") != SPEC["libass"]["commit"]):
        parser.error("input SDK source provenance differs from the lock")
    for relative, expected in marker.get("libraries", {}).items():
        artifact = (prefix / relative).resolve()
        if prefix not in artifact.parents or not artifact.is_file() or digest(artifact) != expected:
            parser.error(f"input SDK hash mismatch: {relative}")
    bash, cygpath = msys / "usr/bin/bash.exe", msys / "usr/bin/cygpath.exe"
    if not bash.is_file() or not cygpath.is_file():
        parser.error(f"MSYS2 bash/cygpath missing under {msys}")
    build.mkdir(parents=True, exist_ok=True)
    unix = lambda path: run([str(cygpath), "-u", str(path)])
    dav1d = SPEC["dav1d"]
    fetch_source(dav1d_source, dav1d["repository"],
                 dav1d["commit"], dav1d["version"])
    meson_setup = [
        "meson", "setup", unix(dav1d_build), unix(dav1d_source),
        f"--prefix={unix(prefix)}", "--libdir=lib", "--buildtype=release",
        "-Ddefault_library=shared", "-Denable_tools=false",
        "-Denable_tests=false",
    ]
    if (dav1d_build / "build.ninja").exists():
        meson_setup.insert(2, "--reconfigure")
    configure = [f"--prefix={unix(prefix)}", f"--libdir={unix(prefix / 'lib')}",
                 "--target-os=mingw32", "--arch=x86_64", "--enable-shared",
                 "--disable-static", "--disable-programs", "--disable-doc",
                 "--enable-network", "--disable-autodetect", "--enable-avfilter",
                 "--enable-swresample", "--enable-swscale", "--enable-d3d11va",
                 "--enable-dxva2", "--enable-libdav1d"]
    script = ("set -euo pipefail\nexport PATH=/mingw64/bin:/usr/bin:$PATH\n"
              f"meson_setup=({ ' '.join(shlex.quote(value) for value in meson_setup) })\n"
              '"${meson_setup[@]}"\n'
              f"meson compile -C {shlex.quote(unix(dav1d_build))} -j{args.jobs}\n"
              f"meson install -C {shlex.quote(unix(dav1d_build))}\n"
              f"export PKG_CONFIG_PATH={shlex.quote(unix(prefix / 'lib/pkgconfig'))}\n"
              f"cd {shlex.quote(unix(build))}\n"
              f"{shlex.quote(unix(source / 'configure'))} " +
              " ".join(shlex.quote(value) for value in configure) + "\n"
              f"make -j{args.jobs}\nmake install\n")
    env = dict(os.environ)
    env["MSYSTEM"] = "MINGW64"
    env["CHERE_INVOKING"] = "1"
    subprocess.run([str(bash), "-lc", script], env=env, check=True)
    dav1d_dlls = sorted((prefix / "bin").glob("*dav1d*.dll"))
    if len(dav1d_dlls) != 1:
        raise RuntimeError("Expected exactly one pinned dav1d runtime DLL")
    dav1d_dll = dav1d_dlls[0]
    marker["dav1d"] = {
        "version": dav1d["version"], "commit": dav1d["commit"],
        "library": dav1d_dll.relative_to(prefix).as_posix(),
        "sha256": digest(dav1d_dll),
    }
    marker["libraries"][dav1d_dll.relative_to(prefix).as_posix()] = digest(dav1d_dll)
    marker["configure"] = configure
    for relative in marker["libraries"]:
        path = prefix / relative
        if not path.is_file():
            raise RuntimeError(f"Previously recorded SDK library disappeared: {relative}")
        marker["libraries"][relative] = digest(path)
    marker["libass"]["sha256"] = digest(prefix / marker["libass"]["library"])
    marker_file.write_text(json.dumps(marker, indent=2, sort_keys=True) + "\n",
                           encoding="utf-8")
    print(f"Rebuilt pinned Windows FFmpeg with network input: {prefix}")


if __name__ == "__main__":
    main()
