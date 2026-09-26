"""Build the pinned FFmpeg C SDK; no existing libmpv bundle is accepted.

Currently this builder supports native Linux. Cross-platform prefixes must be
produced by target-specific builders and pass verify_core_dependencies.py.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys


ROOT = Path(__file__).resolve().parent
SPEC = json.loads((ROOT / "core_dependencies.json").read_text(encoding="utf-8"))


def run(args: list[str], cwd: Path | None = None) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def locked_ffmpeg_patches() -> dict[str, Path]:
    patches: dict[str, Path] = {}
    for relative, expected in SPEC["ffmpeg"].get("patches", {}).items():
        path = (ROOT / relative).resolve()
        if ROOT.resolve() not in path.parents or not path.is_file():
            raise RuntimeError(f"Missing/unsafe FFmpeg patch: {relative}")
        if sha256(path) != expected:
            raise RuntimeError(f"FFmpeg patch hash mismatch: {relative}")
        patches[relative] = path
    return patches


def fetch_source(source: Path, repository: str, commit: str, tag: str) -> None:
    if not source.exists():
        source.mkdir()
    if not (source / ".git").is_dir():
        if any(source.iterdir()):
            raise RuntimeError(f"Source path is not a Git repository: {source}")
        run(["git", "init", str(source)])
        run(["git", "remote", "add", "origin", repository], source)
    if run(["git", "remote", "get-url", "origin"], source) != repository:
        raise RuntimeError(f"Source remote does not match lock: {source}")
    if subprocess.run(["git", "cat-file", "-e", f"{commit}^{{commit}}"],
                      cwd=source, stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL).returncode != 0:
        run(["git", "-c", "protocol.version=2", "fetch", "--depth=1",
             "--filter=blob:none", "origin", commit], source)
    run(["git", "-c", "protocol.version=2", "fetch", "--depth=1",
         "--filter=blob:none", "origin", f"refs/tags/{tag}:refs/tags/{tag}"], source)
    if run(["git", "rev-parse", f"refs/tags/{tag}^{{}}"], source) != commit:
        raise RuntimeError(f"Source release tag does not match pinned commit: {source}")
    run(["git", "checkout", "--detach", commit], source)
    if run(["git", "rev-parse", "HEAD"], source) != commit:
        raise RuntimeError(f"Source commit does not match lock: {source}")
    # Windows bind mounts can lose executable mode on checked-out shell scripts.
    # Ignore only that host filesystem metadata; still reject changed bytes and
    # untracked source files before building the pinned commit.
    if run(["git", "-c", "core.filemode=false", "status", "--porcelain"], source):
        raise RuntimeError(f"Source tree has local changes: {source}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 2)
    parser.add_argument("--with-libass", action="store_true",
                        help="build pinned libass 0.17.5 for ASS/SSA composition")
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        parser.error("native builder currently supports Linux x86_64 only")
    prefix = args.prefix.resolve()
    work = args.work.resolve()
    if prefix == work or prefix in work.parents or work in prefix.parents:
        parser.error("prefix and work must be separate directories")
    prefix.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    dav1d_spec = SPEC["dav1d"]
    dav1d_source = work / "dav1d"
    dav1d_build = work / "dav1d-build"
    fetch_source(dav1d_source, dav1d_spec["repository"],
                 dav1d_spec["commit"], dav1d_spec["version"])
    dav1d_setup = [
        "meson", "setup", str(dav1d_build), str(dav1d_source),
        f"--prefix={prefix}", "--libdir=lib", "--buildtype=release",
        "-Ddefault_library=shared", "-Denable_tools=false",
        "-Denable_tests=false",
    ]
    if (dav1d_build / "build.ninja").exists():
        dav1d_setup.insert(2, "--reconfigure")
    run(dav1d_setup)
    run(["meson", "compile", "-C", str(dav1d_build), "-j", str(args.jobs)])
    run(["meson", "install", "-C", str(dav1d_build)])
    dav1d_libraries = [path for path in (prefix / "lib").glob("libdav1d.so.*")
                       if path.is_file() and not path.is_symlink()]
    if not dav1d_libraries:
        raise RuntimeError("pinned dav1d library was not installed")
    dav1d_library = max(dav1d_libraries, key=lambda path: len(path.name))
    os.environ["PKG_CONFIG_PATH"] = str(prefix / "lib/pkgconfig") + os.pathsep + \
        os.environ.get("PKG_CONFIG_PATH", "")
    source = work / "ffmpeg"
    build = work / "ffmpeg-build"
    commit = SPEC["ffmpeg"]["commit"]
    tag = SPEC["ffmpeg"]["version"]
    repository = SPEC["ffmpeg"]["repository"]
    patches = locked_ffmpeg_patches()
    if (source / ".git").is_dir():
        for path in patches.values():
            if subprocess.run(["git", "apply", "--reverse", "--check", str(path)],
                              cwd=source, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0:
                run(["git", "apply", "--reverse", str(path)], source)
    fetch_source(source, repository, commit, tag)
    for path in patches.values():
        run(["git", "apply", "--check", str(path)], source)
        run(["git", "apply", str(path)], source)
    for dependency in ("libva", "libva-drm", "libdrm"):
        run(["pkg-config", "--exists", dependency])
    build.mkdir(parents=True, exist_ok=True)
    configure = [
        str(source / "configure"), f"--prefix={prefix}", "--libdir=" + str(prefix / "lib"),
        "--enable-shared", "--disable-static", "--disable-programs", "--disable-doc",
        "--enable-network", "--enable-pic", "--enable-avfilter",
        "--enable-swresample", "--enable-swscale", "--enable-vaapi",
        "--enable-libdrm", "--enable-libdav1d",
    ]
    run(configure, build)
    run(["make", f"-j{args.jobs}"], build)
    run(["make", "install"], build)
    artifacts: dict[str, str] = {}
    for name in SPEC["ffmpeg"]["libraries"]:
        candidates = list((prefix / "lib").glob(f"lib{name}.so.*"))
        candidates = [path for path in candidates if path.is_file() and not path.is_symlink()]
        if not candidates:
            raise RuntimeError(f"missing built library: {name}")
        selected = max(candidates, key=lambda path: len(path.name))
        artifacts[str(selected.relative_to(prefix))] = sha256(selected)
    libass_marker = None
    if args.with_libass:
        for dependency in SPEC["libass"]["required_build_dependencies"]:
            run(["pkg-config", "--exists", dependency])
        run(["pkg-config", "--atleast-version=2.10.92", "fontconfig"])
        ass_spec = SPEC["libass"]
        ass_source = work / "libass"
        ass_build = work / "libass-build"
        fetch_source(ass_source, ass_spec["repository"],
                     ass_spec["commit"], ass_spec["version"])
        meson_args = ["meson", "setup", str(ass_build), str(ass_source),
                      f"--prefix={prefix}", "--libdir=lib",
                      "--buildtype=release", "-Ddefault_library=shared",
                      "-Dfontconfig=enabled",
                      "-Drequire-system-font-provider=true"]
        if (ass_build / "build.ninja").exists():
            meson_args.insert(2, "--reconfigure")
        run(meson_args)
        run(["meson", "compile", "-C", str(ass_build), "-j", str(args.jobs)])
        run(["meson", "install", "-C", str(ass_build)])
        ass_candidates = [path for path in (prefix / "lib").glob("libass.so.*")
                          if path.is_file() and not path.is_symlink()]
        if not ass_candidates:
            raise RuntimeError("pinned libass shared library was not installed")
        ass_library = max(ass_candidates, key=lambda path: len(path.name))
        libass_marker = {
            "version": ass_spec["version"],
            "commit": ass_spec["commit"],
            "library": str(ass_library.relative_to(prefix)),
            "sha256": sha256(ass_library),
            "build_dependencies": {
                name: run(["pkg-config", "--modversion", name])
                for name in ass_spec["required_build_dependencies"]
            },
        }
    marker = {
        "schema": 1,
        "platform": "linux-x64",
        "ffmpeg_version": SPEC["ffmpeg"]["version"],
        "ffmpeg_commit": commit,
        "ffmpeg_tag": tag,
        "ffmpeg_patches": SPEC["ffmpeg"].get("patches", {}),
        "libraries": artifacts,
        "configure": configure[1:],
        "vaapi_build_dependencies": {
            name: run(["pkg-config", "--modversion", name])
            for name in ("libva", "libva-drm", "libdrm")
        },
        "dav1d": {
            "version": dav1d_spec["version"],
            "commit": dav1d_spec["commit"],
            "library": str(dav1d_library.relative_to(prefix)),
            "sha256": sha256(dav1d_library),
        },
    }
    if libass_marker:
        marker["libass"] = libass_marker
    (prefix / "rillight-core-dependencies.json").write_text(
        json.dumps(marker, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(f"Built verified FFmpeg SDK: {prefix}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Core dependency build failed: {error}", file=sys.stderr)
        sys.exit(1)
