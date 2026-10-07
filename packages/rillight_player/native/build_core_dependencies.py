"""Build the pinned FFmpeg C SDK; no existing libmpv bundle is accepted.

Currently this builder supports native Linux. Cross-platform prefixes must be
produced by target-specific builders and pass verify_core_dependencies.py.
``--stage-enhancement-only`` clones pinned ncnn and downloads the hash-matched
RIFE v4.6 and realesr-general-x4v3 weights. A missing or mismatched file fails.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import urllib.request

from build_subtitle_unicode import meson_source


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


def locked_ffmpeg_patches(platform_name: str | None = None) -> dict[str, Path]:
    patches: dict[str, Path] = {}
    hashes = dict(SPEC["ffmpeg"].get("patches", {}))
    hashes.update(SPEC["ffmpeg"].get("platform_patches", {}).get(platform_name, {}))
    for relative, expected in hashes.items():
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
    # `remote get-url` expands a host's url.*.insteadOf mirror rule. Verify the
    # URL stored in this repository; the pinned commit and tag are checked below.
    if run(["git", "config", "--local", "--get", "remote.origin.url"], source) != repository:
        raise RuntimeError(f"Source remote does not match lock: {source}")
    if subprocess.run(["git", "cat-file", "-e", f"{commit}^{{commit}}"],
                      cwd=source, stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL).returncode != 0:
        run(["git", "-c", "protocol.version=2", "fetch", "--depth=1",
             "origin", commit], source)
    run(["git", "-c", "protocol.version=2", "fetch", "--depth=1",
         "origin", f"refs/tags/{tag}:refs/tags/{tag}"], source)
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


def require_pinned_file(path: Path, record: dict, label: str) -> None:
    if not path.is_file():
        raise RuntimeError(f"Missing enhancement file: {label}")
    actual = sha256(path)
    size = path.stat().st_size
    if actual != record["sha256"] or size != record["bytes"]:
        raise RuntimeError(
            f"Enhancement pin mismatch: {label} sha256={actual} bytes={size}")


def enhancement_dirs(root: Path | None = None) -> tuple[Path, Path]:
    base = root if root is not None else ROOT.parents[2] / "build"
    return base / "enhancement-src" / "ncnn", base / "enhancement-models"


def verify_anime4k_shaders() -> None:
    spec = SPEC["enhancement"]["anime4k"]["shaders"]
    shader_dir = ROOT / "core" / "shaders" / "anime4k"
    for name, record in spec.items():
        require_pinned_file(shader_dir / name, record, name)


def verify_enhancement_models(model_root: Path) -> list[str]:
    spec = SPEC["enhancement"]
    files = dict(spec["rife"]["files"])
    files.update(spec["realesrgan"]["ncnn_weights"]["files"])
    if len(files) != 4:
        raise RuntimeError("Enhancement model pin is incomplete")
    checked: list[str] = []
    for relative, record in files.items():
        require_pinned_file(model_root / Path(relative), record, relative)
        checked.append(relative)
    return checked


def download_verified(url: str, dest: Path, record: dict, label: str) -> None:
    if dest.is_file():
        try:
            require_pinned_file(dest, record, label)
            return
        except RuntimeError:
            dest.unlink()
    dest.parent.mkdir(parents=True, exist_ok=True)
    partial = dest.with_name(dest.name + ".partial")
    request = urllib.request.Request(url, headers={"User-Agent": "rillight-core"})
    try:
        with urllib.request.urlopen(request, timeout=180) as response, partial.open("wb") as output:
            shutil.copyfileobj(response, output)
        require_pinned_file(partial, record, label)
    except Exception:
        partial.unlink(missing_ok=True)
        raise
    partial.replace(dest)


def stage_ncnn(ncnn_dir: Path) -> None:
    spec = SPEC["enhancement"]["ncnn"]
    if ncnn_dir.exists() and not (ncnn_dir / ".git").is_dir():
        shutil.rmtree(ncnn_dir)
    ncnn_dir.parent.mkdir(parents=True, exist_ok=True)
    fetch_source(ncnn_dir, spec["repository"], spec["commit"], spec["version"])
    if not (ncnn_dir / "CMakeLists.txt").is_file():
        raise RuntimeError(f"Pinned ncnn has no CMake project: {ncnn_dir}")


def stage_model_files(model_root: Path) -> list[str]:
    spec = SPEC["enhancement"]
    model_root.mkdir(parents=True, exist_ok=True)
    rife = spec["rife"]
    for relative, record in rife["files"].items():
        url = (f"https://raw.githubusercontent.com/nihui/rife-ncnn-vulkan/"
               f"{rife['commit']}/models/{relative}")
        download_verified(url, model_root / Path(relative), record, relative)
    for name, record in spec["realesrgan"]["ncnn_weights"]["files"].items():
        download_verified(record["url"], model_root / name, record, name)
    return verify_enhancement_models(model_root)


def stage_enhancement(root: Path | None = None) -> tuple[Path, Path]:
    verify_anime4k_shaders()
    ncnn_dir, model_root = enhancement_dirs(root)
    stage_ncnn(ncnn_dir)
    checked = stage_model_files(model_root)
    print(f"Enhancement staged: ncnn {SPEC['enhancement']['ncnn']['commit']} "
          f"and {len(checked)} model files")
    return ncnn_dir, model_root


def install_enhancement_runtime(source_dir: Path, destination: Path) -> None:
    """Copy hash-pinned weights and Anime4K shaders next to a built library."""
    names = [
        "rife-v4.6/flownet.param",
        "rife-v4.6/flownet.bin",
        "realesr-general-x4v3.param",
        "realesr-general-x4v3.bin",
    ]
    records = dict(SPEC["enhancement"]["rife"]["files"])
    records.update(SPEC["enhancement"]["realesrgan"]["ncnn_weights"]["files"])
    for relative in names:
        source = source_dir / Path(relative)
        require_pinned_file(source, records[relative], relative)
        dest = destination / Path(relative)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, dest)
    shader_dir = source_dir / "shaders" / "anime4k"
    shaders = SPEC["enhancement"]["anime4k"]["shaders"]
    for name, record in shaders.items():
        source = shader_dir / name
        require_pinned_file(source, record, name)
        dest = destination / "shaders" / "anime4k" / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, dest)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path)
    parser.add_argument("--work", type=Path)
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 2)
    parser.add_argument("--with-libass", action="store_true",
                        help="build pinned libass 0.17.5 for ASS/SSA composition")
    parser.add_argument("--stage-enhancement-only", action="store_true",
                        help="clone pinned ncnn and fetch hash-matched model files")
    parser.add_argument("--enhancement-root", type=Path,
                        help="parent of enhancement-src and enhancement-models")
    args = parser.parse_args()
    if args.stage_enhancement_only:
        stage_enhancement(args.enhancement_root.resolve() if args.enhancement_root else None)
        return 0
    if args.prefix is None or args.work is None:
        parser.error("--prefix and --work are required")
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        parser.error("native builder currently supports Linux x86_64 only")
    stage_enhancement(args.enhancement_root.resolve() if args.enhancement_root else None)
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
        "--enable-decoder=ac3", "--enable-decoder=eac3", "--enable-decoder=truehd",
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
        unicode_spec = ass_spec["unicode_line_breaks"]
        unicode_source = work / "libunibreak"
        fetch_source(unicode_source, unicode_spec["repository"], unicode_spec["commit"], unicode_spec["tag"])
        unicode_project = meson_source(unicode_source, work / "libunibreak-project", unicode_spec["version"])
        unicode_build = work / "libunibreak-build"
        setup = ["meson", "setup", str(unicode_build), str(unicode_project),
                 f"--prefix={prefix}", "--libdir=lib", "--buildtype=release"]
        if (unicode_build / "build.ninja").exists(): setup.insert(2, "--reconfigure")
        run(setup)
        run(["meson", "compile", "-C", str(unicode_build), "-j", str(args.jobs)])
        run(["meson", "install", "-C", str(unicode_build)])
        os.environ["PKG_CONFIG_PATH"] = str(prefix / "lib/pkgconfig") + os.pathsep + os.environ.get("PKG_CONFIG_PATH", "")
        ass_source = work / "libass"
        ass_build = work / "libass-build"
        fetch_source(ass_source, ass_spec["repository"],
                     ass_spec["commit"], ass_spec["version"])
        meson_args = ["meson", "setup", str(ass_build), str(ass_source),
                      f"--prefix={prefix}", "--libdir=lib",
                      "--buildtype=release", "-Ddefault_library=shared",
                      "-Dfontconfig=enabled", "-Dlibunibreak=enabled",
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
            "unicode_line_breaks": unicode_spec,
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
