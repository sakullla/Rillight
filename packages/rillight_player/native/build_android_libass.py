"""Add pinned libass and static shaping dependencies to Android core SDKs.

The FFmpeg SDK must already exist. Android has no system Fontconfig provider;
the core selects a bundled Android system font at runtime instead.
"""

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

from build_android_core_dependencies import ABIS
from build_core_dependencies import SPEC, fetch_source, run, sha256
from verify_core_dependencies import verify


def pinned_source(path: Path, specification: dict[str, str], tag: str) -> Path:
    if path.is_dir() and (path / ".git").is_dir():
        changed = [line.strip() for line in run(["git", "-c", "core.filemode=false", "status", "--porcelain"], path).splitlines()]
        # HarfBuzz's Meson generator writes version/umbrella headers into its
        # checkout. Restore only those known generated paths before pin checks.
        generated = {"M src/harfbuzz-subset.cc", "M src/harfbuzz.cc", "M src/hb-version.h"}
        if changed and set(changed) <= generated:
            for entry in changed:
                relative = entry[2:]
                original = subprocess.check_output(["git", "show", f"HEAD:{relative}"], cwd=path)
                (path / relative).write_bytes(original)
            changed = [line.strip() for line in run(["git", "-c", "core.filemode=false", "status", "--porcelain"], path).splitlines()]
        clean = not changed or (
            set(changed) <= generated and
            subprocess.run(["git", "-c", "core.filemode=false", "diff", "--quiet"],
                           cwd=path).returncode == 0
        )
        if (run(["git", "rev-parse", "HEAD"], path) == specification["commit"] and
                run(["git", "rev-parse", f"refs/tags/{tag}^{{}}"], path) == specification["commit"] and
                clean):
            return path
    fetch_source(path, specification["repository"], specification["commit"], tag)
    return path


def cross_file(path: Path, *, ndk_bin: Path, abi: str, prefix: Path,
               pkg_config: Path) -> None:
    arch, triple, _ = ABIS[abi]
    extension = ".exe" if os.name == "nt" else ""
    def tool(name: str) -> str:
        return (ndk_bin / (name + extension)).as_posix()
    cpu = {"arm64-v8a": "aarch64", "armeabi-v7a": "armv7", "x86_64": "x86_64"}[abi]
    pkgdir = (prefix / "lib" / "pkgconfig").as_posix()
    path.write_text(
        "[binaries]\n"
        f"c = '{tool('clang')}'\n"
        f"cpp = '{tool('clang++')}'\n"
        f"ar = '{tool('llvm-ar')}'\n"
        f"strip = '{tool('llvm-strip')}'\n"
        f"pkg-config = '{pkg_config.as_posix()}'\n"
        "[properties]\n"
        "needs_exe_wrapper = true\n"
        f"sys_root = '{prefix.as_posix()}'\n"
        f"pkg_config_libdir = '{pkgdir}'\n"
        "[built-in options]\n"
        f"c_args = ['--target={triple}', '-fPIC']\n"
        f"cpp_args = ['--target={triple}', '-fPIC']\n"
        f"c_link_args = ['--target={triple}']\n"
        f"cpp_link_args = ['--target={triple}']\n"
        "[host_machine]\n"
        "system = 'android'\n"
        f"cpu_family = '{arch}'\n"
        f"cpu = '{cpu}'\n"
        "endian = 'little'\n",
        encoding="utf-8",
    )


def meson_build(source: Path, build: Path, prefix: Path, cross: Path, native: Path,
                options: list[str], jobs: int, meson: Path) -> None:
    environment = os.environ.copy()
    if os.name == "nt":
        environment["PATH"] = str(meson.parent) + os.pathsep + environment.get("PATH", "")
    setup = [str(meson), "setup", str(build), str(source),
             "--cross-file", str(cross), "--native-file", str(native), "--prefix=/",
             "--libdir=lib", "--buildtype=release", *options]
    if (build / "build.ninja").is_file():
        setup.insert(2, "--reconfigure")
    subprocess.run(setup, check=True, env=environment)
    subprocess.run([str(meson), "compile", "-C", str(build), "-j", str(jobs)], check=True,
                   env=environment)
    subprocess.run([str(meson), "install", "-C", str(build),
                    "--destdir", str(prefix)], check=True, env=environment)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix-root", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--ndk", type=Path, required=True)
    parser.add_argument("--abis", nargs="+", choices=ABIS, default=list(ABIS))
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--meson", type=Path, default=shutil.which("meson") or "C:/msys64/mingw64/bin/meson.exe")
    parser.add_argument("--pkg-config", type=Path, default=shutil.which("pkg-config") or "C:/msys64/mingw64/bin/pkg-config.exe")
    args = parser.parse_args()
    host = {"Windows": "windows-x86_64", "Linux": "linux-x86_64"}.get(platform.system())
    if host is None or args.jobs < 1:
        parser.error("requires Windows/Linux host and positive --jobs")
    ndk_bin = args.ndk.resolve() / "toolchains" / "llvm" / "prebuilt" / host / "bin"
    if not ndk_bin.is_dir() or not args.meson.is_file() or not args.pkg_config.is_file():
        parser.error("NDK, Meson or pkg-config is missing")
    work = args.work.resolve()
    root = args.prefix_root.resolve()
    work.mkdir(parents=True, exist_ok=True)
    native = work / "mingw-native.ini"
    if os.name == "nt":
        native.write_text(
            "[binaries]\n"
            "c = 'C:/msys64/mingw64/bin/gcc.exe'\n"
            "cpp = 'C:/msys64/mingw64/bin/g++.exe'\n"
            "ar = 'C:/msys64/mingw64/bin/ar.exe'\n"
            "strip = 'C:/msys64/mingw64/bin/strip.exe'\n",
            encoding="utf-8",
        )
    else:
        native.write_text("[binaries]\nc = 'cc'\ncpp = 'c++'\n", encoding="utf-8")
    sources = {}
    for name, specification in SPEC["libass"]["android_sources"].items():
        source = work / name
        sources[name] = pinned_source(source, specification, specification["tag"])
    ass_spec = SPEC["libass"]
    ass_source = work / "libass"
    pinned_source(ass_source, ass_spec, ass_spec["version"])
    for abi in args.abis:
        prefix = root / abi
        existing = verify(prefix, f"android-{abi}")
        if existing:
            raise RuntimeError("; ".join(existing))
        cross = work / f"{abi}.ini"
        cross_file(cross, ndk_bin=ndk_bin, abi=abi, prefix=prefix,
                   pkg_config=args.pkg_config.resolve())
        builds = [
            ("freetype", ["-Ddefault_library=static", "-Dharfbuzz=disabled", "-Dzlib=disabled", "-Dpng=disabled", "-Dbzip2=disabled", "-Dbrotli=disabled"]),
            ("fribidi", ["-Ddefault_library=static", "-Ddocs=false", "-Dtests=false"]),
            ("harfbuzz", ["-Ddefault_library=static", "-Dtests=disabled", "-Dcairo=disabled", "-Dglib=disabled", "-Dgobject=disabled", "-Dfreetype=disabled", "-Dicu=disabled", "-Dintrospection=disabled"]),
            ("libass", ["-Ddefault_library=shared", "-Dfontconfig=disabled", "-Drequire-system-font-provider=false", "-Dlibunibreak=disabled", "-Dtest=disabled", "-Dcompare=disabled", "-Dasm=disabled"]),
        ]
        for name, options in builds:
            print(f"Building {name} for {abi}", flush=True)
            meson_build(ass_source if name == "libass" else sources[name],
                        work / f"{abi}-{name}-mingw", prefix, cross, native,
                        options, args.jobs, args.meson.resolve())
        library = prefix / "lib" / "libass.so"
        if not library.is_file() or not (prefix / "include" / "ass" / "ass.h").is_file():
            raise RuntimeError(f"libass installation incomplete: {abi}")
        machine = run([str(ndk_bin / ("llvm-readelf.exe" if os.name == "nt" else "llvm-readelf")), "-h", str(library)])
        if ABIS[abi][2] not in machine:
            raise RuntimeError(f"wrong ELF machine for libass {abi}")
        marker_file = prefix / "rillight-core-dependencies.json"
        marker = json.loads(marker_file.read_text(encoding="utf-8"))
        marker["libass"] = {
            "version": ass_spec["version"], "commit": ass_spec["commit"],
            "library": "lib/libass.so", "sha256": sha256(library),
            "build_dependencies": {
                "freetype2": SPEC["libass"]["android_sources"]["freetype"]["version"],
                "fribidi": SPEC["libass"]["android_sources"]["fribidi"]["version"],
                "harfbuzz": SPEC["libass"]["android_sources"]["harfbuzz"]["version"],
                "fontconfig": "disabled (Android explicit font path)",
            },
            "android_sources": SPEC["libass"]["android_sources"],
        }
        marker_file.write_text(json.dumps(marker, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        failures = verify(prefix, f"android-{abi}", require_subtitles=True)
        if failures:
            raise RuntimeError("; ".join(failures))
        print(f"Built verified Android libass SDK: {abi}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Android libass build failed: {error}", file=sys.stderr)
        sys.exit(1)
