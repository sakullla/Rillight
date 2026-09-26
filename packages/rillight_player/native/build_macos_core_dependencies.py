"""Build a universal macOS FFmpeg/libass/dav1d SDK from pinned sources.

The output prefix is x86_64+arm64, uses @rpath install names, and must pass
verify_core_dependencies.py --target macos-universal --require-subtitles.
Homebrew and other host prefixes are not linked into the runtime closure.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

from build_core_dependencies import (
    SPEC, fetch_source, locked_ffmpeg_patches, run as capture, sha256)
from prepare_macos import (
    ABI_MAJOR_DYLIB, bundled_names, is_macho, sanitize_install_names)
from verify_core_dependencies import verify

ROOT = Path(__file__).resolve().parent
ARCHES = ("arm64", "x86_64")
DEPLOYMENT_TARGET = "12.0"
MESON = "1.7.2"
NINJA = "1.11.1.4"
SUBTITLE_SOURCES = SPEC["libass"]["android_sources"]
FONTCONFIG_PROVENANCE = "disabled (macOS CoreText)"

FFMPEG_CONFIGURE = [
    "--enable-shared", "--disable-static", "--disable-programs", "--disable-doc",
    "--disable-avdevice", "--enable-network", "--disable-autodetect",
    "--enable-pic", "--enable-avfilter", "--enable-swresample", "--enable-swscale",
    "--enable-videotoolbox", "--enable-libdav1d",
]


def native_arch() -> str:
    machine = platform.machine()
    return "arm64" if machine in ("arm64", "aarch64") else machine


def host_cpu_family(arch: str) -> str:
    return "aarch64" if arch == "arm64" else "x86_64"


def isolated_env(prefix: Path, extras: list[Path]) -> dict[str, str]:
    env = os.environ.copy()
    pkgdir = str(prefix / "lib/pkgconfig")
    env["PKG_CONFIG_LIBDIR"] = pkgdir
    env["PKG_CONFIG_PATH"] = pkgdir
    env["MACOSX_DEPLOYMENT_TARGET"] = DEPLOYMENT_TARGET
    env["CC"] = "clang"
    env["CXX"] = "clang++"
    path = [str(path) for path in extras if path]
    path.extend([
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        "/Applications/Xcode.app/Contents/Developer/usr/bin",
    ])
    env["PATH"] = os.pathsep.join(path)
    env.pop("LDFLAGS", None)
    env.pop("CFLAGS", None)
    env.pop("CXXFLAGS", None)
    env.pop("CPPFLAGS", None)
    return env


def live(args: list[str], cwd: Path | None = None,
         env: dict[str, str] | None = None) -> None:
    print("+", " ".join(args), flush=True)
    subprocess.check_call(args, cwd=cwd, env=env)


def which(name: str, extras: list[Path]) -> Path:
    for directory in extras:
        candidate = directory / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    found = shutil.which(name)
    if not found:
        raise RuntimeError(f"Missing build tool: {name}")
    return Path(found).resolve()


def write_meson_file(path: Path, arch: str, *, cross: bool, pkgdir: Path,
                     nasm: Path, pkg_config: Path) -> None:
    flags = f"['-arch', '{arch}', '-mmacosx-version-min={DEPLOYMENT_TARGET}']"
    properties = (
        "[properties]\n"
        f"needs_exe_wrapper = {'true' if cross else 'false'}\n"
        f"pkg_config_libdir = '{pkgdir.as_posix()}'\n"
    )
    path.write_text(
        "[binaries]\n"
        "c = 'clang'\n"
        "cpp = 'clang++'\n"
        "ar = 'ar'\n"
        "strip = 'strip'\n"
        f"nasm = '{nasm.as_posix()}'\n"
        f"pkg-config = '{pkg_config.as_posix()}'\n"
        f"{properties}"
        "[built-in options]\n"
        f"c_args = {flags}\n"
        f"cpp_args = {flags}\n"
        f"c_link_args = {flags}\n"
        f"cpp_link_args = {flags}\n"
        "[host_machine]\n"
        "system = 'darwin'\n"
        f"cpu_family = '{host_cpu_family(arch)}'\n"
        f"cpu = '{arch}'\n"
        "endian = 'little'\n",
        encoding="utf-8",
    )


def meson_build(meson: Path, source: Path, build: Path, prefix: Path,
                machine_file: Path, options: list[str], jobs: int,
                env: dict[str, str], cross: bool) -> None:
    setup = [str(meson), "setup", str(build), str(source),
             "--cross-file" if cross else "--native-file", str(machine_file),
             f"--prefix={prefix}", "--libdir=lib", "--buildtype=release",
             *options]
    if (build / "build.ninja").is_file():
        setup.insert(2, "--reconfigure")
    live(setup, env=env)
    live([str(meson), "compile", "-C", str(build), "-j", str(jobs)], env=env)
    live([str(meson), "install", "-C", str(build)], env=env)


def pinned_source(path: Path, specification: dict[str, str], tag: str) -> Path:
    if path.is_dir() and (path / ".git").is_dir():
        changed = [line.strip() for line in capture(
            ["git", "-c", "core.filemode=false", "status", "--porcelain"],
            path).splitlines()]
        generated = {"M src/harfbuzz-subset.cc", "M src/harfbuzz.cc",
                     "M src/hb-version.h"}
        if changed and set(changed) <= generated:
            for entry in changed:
                relative = entry[2:]
                original = subprocess.check_output(
                    ["git", "show", f"HEAD:{relative}"], cwd=path)
                (path / relative).write_bytes(original)
            changed = [line.strip() for line in capture(
                ["git", "-c", "core.filemode=false", "status", "--porcelain"],
                path).splitlines()]
        clean = not changed or (
            set(changed) <= generated and
            subprocess.run(["git", "-c", "core.filemode=false", "diff",
                            "--quiet"], cwd=path).returncode == 0
        )
        if (capture(["git", "rev-parse", "HEAD"], path) == specification["commit"]
                and capture(["git", "rev-parse", f"refs/tags/{tag}^{{}}"],
                            path) == specification["commit"]
                and clean):
            return path
    fetch_source(path, specification["repository"], specification["commit"], tag)
    return path


def runtime_dylib_map(libdir: Path) -> dict[str, Path]:
    mapping: dict[str, Path] = {}
    for path in sorted(libdir.glob("*.dylib")):
        if ABI_MAJOR_DYLIB.match(path.name):
            mapping[path.name] = path.resolve() if path.is_symlink() else path
    return mapping


def add_unversioned_symlinks(libdir: Path) -> None:
    for major in sorted(libdir.glob("*.dylib")):
        if not ABI_MAJOR_DYLIB.match(major.name):
            continue
        unversioned = libdir / f"{major.name.rsplit('.', 2)[0]}.dylib"
        if unversioned.exists() or unversioned.is_symlink():
            continue
        unversioned.symlink_to(major.name)


def copy_headers_and_pkgconfig(stage: Path, prefix: Path) -> None:
    include = prefix / "include"
    if include.exists():
        shutil.rmtree(include)
    shutil.copytree(stage / "include", include)
    pkgdir = prefix / "lib/pkgconfig"
    pkgdir.mkdir(parents=True, exist_ok=True)
    source = stage / "lib/pkgconfig"
    if not source.is_dir():
        return
    for pc in source.glob("*.pc"):
        text = pc.read_text(encoding="utf-8").replace(str(stage), str(prefix))
        (pkgdir / pc.name).write_text(text, encoding="utf-8")


def lipo_runtime(stages: dict[str, Path], prefix: Path) -> dict[str, Path]:
    native = stages[native_arch() if native_arch() in stages else next(iter(stages))]
    copy_headers_and_pkgconfig(native, prefix)
    names = None
    for stage in stages.values():
        current = set(runtime_dylib_map(stage / "lib"))
        if names is None:
            names = current
        elif names != current:
            raise RuntimeError("Per-arch runtime dylib sets differ")
    if not names:
        raise RuntimeError("No ABI-major dylibs were installed")
    libdir = prefix / "lib"
    libdir.mkdir(parents=True, exist_ok=True)
    outputs: dict[str, Path] = {}
    for name in sorted(names):
        sources = [runtime_dylib_map(stages[arch] / "lib")[name] for arch in ARCHES]
        destination = libdir / name
        live(["lipo", "-create", *[str(path) for path in sources],
              "-output", str(destination)])
        outputs[name] = destination
    add_unversioned_symlinks(libdir)
    return outputs


def ffmpeg_configure(arch: str, source: Path, prefix: Path) -> list[str]:
    flags = [
        str(source / "configure"),
        f"--prefix={prefix}",
        f"--libdir={prefix / 'lib'}",
        f"--arch={arch}",
        "--target-os=darwin",
        "--cc=clang",
        "--cxx=clang++",
        f"--extra-cflags=-arch {arch} -mmacosx-version-min={DEPLOYMENT_TARGET}",
        f"--extra-ldflags=-arch {arch} -mmacosx-version-min={DEPLOYMENT_TARGET}",
        *FFMPEG_CONFIGURE,
    ]
    if arch != native_arch():
        flags.append("--enable-cross-compile")
    return flags


def restore_ffmpeg_tree(source: Path, patches: dict[str, Path]) -> None:
    if (source / ".git").is_dir():
        for path in patches.values():
            if subprocess.run(["git", "apply", "--reverse", "--check", str(path)],
                              cwd=source, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0:
                capture(["git", "apply", "--reverse", str(path)], source)


def sanitize_prefix(prefix: Path, outputs: dict[str, Path]) -> None:
    names = bundled_names(outputs.values())
    for path in outputs.values():
        if not is_macho(path):
            raise RuntimeError(f"Installed library is not Mach-O: {path.name}")
        sanitize_install_names(path, names)


def marker_libraries(prefix: Path, outputs: dict[str, Path]) -> dict[str, str]:
    artifacts: dict[str, str] = {}
    for name, path in sorted(outputs.items()):
        relative = str(path.relative_to(prefix))
        artifacts[relative] = sha256(path)
    return artifacts


def select_named(outputs: dict[str, Path], stem: str) -> Path:
    matches = [path for name, path in outputs.items() if name.startswith(f"lib{stem}.")]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one runtime lib{stem}.dylib, found {len(matches)}")
    return matches[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 2)
    parser.add_argument("--with-libass", action="store_true", default=True)
    parser.add_argument("--skip-libass", action="store_true")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("the macOS SDK must be built on macOS")
    if native_arch() not in ARCHES:
        parser.error(f"unsupported host architecture: {platform.machine()}")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    with_libass = args.with_libass and not args.skip_libass
    prefix = args.prefix.resolve()
    work = args.work.resolve()
    if prefix == work or prefix in work.parents or work in prefix.parents:
        parser.error("prefix and work must be separate directories")
    prefix.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    extras = [
        (work / "venv/bin").resolve(),
        Path("/opt/homebrew/bin"),
        Path("/usr/local/bin"),
    ]
    meson = which("meson", extras)
    nasm = which("nasm", extras)
    pkg_config = which("pkg-config", extras)
    patches = locked_ffmpeg_patches()
    ffmpeg_source = work / "ffmpeg"
    restore_ffmpeg_tree(ffmpeg_source, patches)
    fetch_source(ffmpeg_source, SPEC["ffmpeg"]["repository"],
                 SPEC["ffmpeg"]["commit"], SPEC["ffmpeg"]["version"])
    for path in patches.values():
        capture(["git", "apply", "--check", str(path)], ffmpeg_source)
        capture(["git", "apply", str(path)], ffmpeg_source)
    dav1d_spec = SPEC["dav1d"]
    dav1d_source = pinned_source(work / "dav1d", dav1d_spec, dav1d_spec["version"])
    ass_spec = SPEC["libass"]
    ass_source = None
    subtitle_sources: dict[str, Path] = {}
    if with_libass:
        ass_source = pinned_source(work / "libass", ass_spec, ass_spec["version"])
        for name, specification in SUBTITLE_SOURCES.items():
            subtitle_sources[name] = pinned_source(
                work / name, specification, specification["tag"])
    stages: dict[str, Path] = {}
    for arch in ARCHES:
        stage = work / f"stage-{arch}"
        if stage.exists():
            shutil.rmtree(stage)
        stage.mkdir(parents=True)
        stages[arch] = stage
        env = isolated_env(stage, extras)
        pkgdir = stage / "lib/pkgconfig"
        pkgdir.mkdir(parents=True)
        machine_file = work / f"{arch}.ini"
        cross = arch != native_arch()
        write_meson_file(machine_file, arch, cross=cross, pkgdir=pkgdir,
                         nasm=nasm, pkg_config=pkg_config)
        print(f"Building dav1d for {arch}", flush=True)
        meson_build(meson, dav1d_source, work / f"dav1d-{arch}", stage,
                    machine_file,
                    ["-Ddefault_library=shared", "-Denable_tools=false",
                     "-Denable_tests=false"],
                    args.jobs, env, cross)
        if with_libass:
            builds = [
                ("freetype", subtitle_sources["freetype"],
                 ["-Ddefault_library=static", "-Dharfbuzz=disabled",
                  "-Dzlib=disabled", "-Dpng=disabled", "-Dbzip2=disabled",
                  "-Dbrotli=disabled"]),
                ("fribidi", subtitle_sources["fribidi"],
                 ["-Ddefault_library=static", "-Ddocs=false", "-Dtests=false"]),
                ("harfbuzz", subtitle_sources["harfbuzz"],
                 ["-Ddefault_library=static", "-Dtests=disabled",
                  "-Dcairo=disabled", "-Dglib=disabled", "-Dgobject=disabled",
                  "-Dfreetype=disabled", "-Dicu=disabled",
                  "-Dintrospection=disabled"]),
                ("libass", ass_source,
                 ["-Ddefault_library=shared", "-Dfontconfig=disabled",
                  "-Dcoretext=enabled", "-Drequire-system-font-provider=true",
                  "-Dlibunibreak=disabled", "-Dtest=disabled",
                  "-Dcompare=disabled"]),
            ]
            for name, source, options in builds:
                print(f"Building {name} for {arch}", flush=True)
                meson_build(meson, source, work / f"{name}-{arch}", stage,
                            machine_file, options, args.jobs, env, cross)
        ffmpeg_build = work / f"ffmpeg-{arch}"
        if ffmpeg_build.exists():
            shutil.rmtree(ffmpeg_build)
        ffmpeg_build.mkdir()
        print(f"Building FFmpeg for {arch}", flush=True)
        live(ffmpeg_configure(arch, ffmpeg_source, stage), cwd=ffmpeg_build, env=env)
        live(["make", f"-j{args.jobs}"], cwd=ffmpeg_build, env=env)
        live(["make", "install"], cwd=ffmpeg_build, env=env)
    outputs = lipo_runtime(stages, prefix)
    sanitize_prefix(prefix, outputs)
    dav1d_library = select_named(outputs, "dav1d")
    artifacts = marker_libraries(prefix, outputs)
    marker = {
        "schema": 1,
        "platform": "macos-universal",
        "ffmpeg_version": SPEC["ffmpeg"]["version"],
        "ffmpeg_commit": SPEC["ffmpeg"]["commit"],
        "ffmpeg_tag": SPEC["ffmpeg"]["version"],
        "ffmpeg_patches": SPEC["ffmpeg"].get("patches", {}),
        "libraries": artifacts,
        "configure": FFMPEG_CONFIGURE,
        "architectures": list(ARCHES),
        "macos_deployment_target": DEPLOYMENT_TARGET,
        "dav1d": {
            "version": dav1d_spec["version"],
            "commit": dav1d_spec["commit"],
            "library": str(dav1d_library.relative_to(prefix)),
            "sha256": sha256(dav1d_library),
        },
    }
    if with_libass:
        ass_library = select_named(outputs, "ass")
        marker["libass"] = {
            "version": ass_spec["version"],
            "commit": ass_spec["commit"],
            "library": str(ass_library.relative_to(prefix)),
            "sha256": sha256(ass_library),
            "build_dependencies": {
                "freetype2": SUBTITLE_SOURCES["freetype"]["version"],
                "fribidi": SUBTITLE_SOURCES["fribidi"]["version"],
                "harfbuzz": SUBTITLE_SOURCES["harfbuzz"]["version"],
                "fontconfig": FONTCONFIG_PROVENANCE,
            },
            "sources": SUBTITLE_SOURCES,
        }
    (prefix / "rillight-core-dependencies.json").write_text(
        json.dumps(marker, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    failures = verify(prefix, "macos-universal", require_subtitles=with_libass)
    if failures:
        raise RuntimeError("macOS SDK verification failed: " + "; ".join(failures))
    print(f"Built verified macOS universal FFmpeg SDK: {prefix}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"macOS core dependency build failed: {error}", file=sys.stderr)
        sys.exit(1)
