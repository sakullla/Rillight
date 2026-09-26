"""Build pinned FFmpeg development SDKs for Android ABIs with the NDK.

Windows needs MSYS2 Bash, make, and a MinGW host compiler. Linux needs Bash,
make, and a host C compiler. This does not build libass or certify a release
library closure; use it to compile and test the Android core before packaging.
"""

import argparse
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys

from build_core_dependencies import (
    SPEC,
    fetch_source,
    locked_ffmpeg_patches,
    run,
    sha256,
)
from verify_core_dependencies import verify


ABIS = {
    "arm64-v8a": ("aarch64", "aarch64-linux-android24", "AArch64"),
    "armeabi-v7a": ("arm", "armv7a-linux-androideabi24", "ARM"),
    "x86_64": ("x86_64", "x86_64-linux-android24", "X86-64"),
}


def posix_path(path: Path, bash: Path) -> str:
    if os.name != "nt":
        return path.as_posix()
    return subprocess.check_output(
        [str(bash), "-lc", 'cygpath -u "$1"', "bash", str(path)],
        text=True,
    ).strip()


def prepare_source(source: Path) -> None:
    patches = locked_ffmpeg_patches()
    if (source / ".git").is_dir():
        for patch in patches.values():
            if subprocess.run(
                ["git", "apply", "--reverse", "--check", str(patch)],
                cwd=source, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            ).returncode == 0:
                run(["git", "apply", "--reverse", str(patch)], source)
    ffmpeg = SPEC["ffmpeg"]
    fetch_source(source, ffmpeg["repository"], ffmpeg["commit"], ffmpeg["version"])
    for patch in patches.values():
        run(["git", "apply", "--check", str(patch)], source)
        run(["git", "apply", str(patch)], source)


def verify_supplied_source(source: Path) -> None:
    if run(["git", "rev-parse", "HEAD"], source) != SPEC["ffmpeg"]["commit"]:
        raise RuntimeError("supplied FFmpeg source is not the locked commit")
    patches = locked_ffmpeg_patches()
    if len(patches) != 1:
        raise RuntimeError("Android builder requires one locked FFmpeg patch")
    expected_diff = next(iter(patches.values())).read_bytes()
    actual_diff = subprocess.check_output(
        ["git", "-c", "core.filemode=false", "diff", "--binary", "HEAD", "--"],
        cwd=source,
    )
    if actual_diff != expected_diff:
        raise RuntimeError("supplied FFmpeg source differs from the locked patch")
    changed = subprocess.check_output(
        ["git", "-c", "core.filemode=false", "status", "--porcelain"],
        cwd=source, text=True,
    )
    if changed.splitlines() != [" M libavformat/hls.c"]:
        raise RuntimeError(f"unexpected files in supplied FFmpeg source: {changed}")


def build_abi(
    *, abi: str, prefix_root: Path, work: Path, source: Path,
    ndk_bin: Path, bash: Path, jobs: int,
) -> None:
    arch, triple, machine = ABIS[abi]
    prefix = prefix_root / abi
    build = work / f"android-ffmpeg-build-{abi}"
    prefix.mkdir(parents=True, exist_ok=True)
    build.mkdir(parents=True, exist_ok=True)
    source_sh = posix_path(source, bash)
    build_sh = posix_path(build, bash)
    prefix_sh = posix_path(prefix, bash)
    ndk_sh = posix_path(ndk_bin, bash)
    suffix = ".exe" if os.name == "nt" else ""
    host_cc = "/mingw64/bin/gcc.exe" if os.name == "nt" else "cc"
    args = [
        f"--prefix={prefix_sh}", f"--libdir={prefix_sh}/lib",
        "--target-os=android", f"--arch={arch}", "--enable-cross-compile",
        f"--cc={ndk_sh}/clang{suffix}", f"--cxx={ndk_sh}/clang++{suffix}",
        f"--host-cc={host_cc}", f"--ld={ndk_sh}/clang{suffix}",
        f"--ar={ndk_sh}/llvm-ar{suffix}",
        f"--ranlib={ndk_sh}/llvm-ranlib{suffix}",
        f"--strip={ndk_sh}/llvm-strip{suffix}",
        f"--extra-cflags=--target={triple} -fPIC",
        f"--extra-cxxflags=--target={triple} -fPIC",
        f"--extra-ldflags=--target={triple}",
        "--enable-shared", "--disable-static", "--disable-programs",
        "--disable-doc", "--disable-network", "--disable-autodetect",
        "--disable-asm", "--enable-pic", "--enable-avfilter",
        "--enable-swresample", "--enable-swscale", "--enable-jni",
        "--enable-mediacodec",
    ]
    script = "\n".join([
        "set -euo pipefail",
        f'export PATH="/usr/bin:/mingw64/bin:{ndk_sh}:$PATH"'
        if os.name == "nt" else f'export PATH="{ndk_sh}:$PATH"',
        f"cd {shlex.quote(build_sh)}",
        " ".join([shlex.quote(f"{source_sh}/configure"),
                  *(shlex.quote(value) for value in args)]),
        f"make -j{jobs}",
        "make install",
        "",
    ])
    script_path = work / f"build-android-{abi}.sh"
    script_path.write_text(script, encoding="utf-8", newline="\n")
    subprocess.run([str(bash), posix_path(script_path, bash)], check=True)
    readelf = ndk_bin / ("llvm-readelf.exe" if os.name == "nt" else "llvm-readelf")
    libraries = {}
    for component in SPEC["ffmpeg"]["libraries"]:
        library = prefix / "lib" / f"lib{component}.so"
        if not library.is_file():
            raise RuntimeError(f"missing Android library: {library}")
        header = run([str(readelf), "-h", str(library)])
        if machine not in header:
            raise RuntimeError(f"wrong ELF machine for {abi}: {library}")
        libraries[library.relative_to(prefix).as_posix()] = sha256(library)
    marker = {
        "schema": 1,
        "platform": f"android-{abi}",
        "ffmpeg_version": SPEC["ffmpeg"]["version"],
        "ffmpeg_commit": SPEC["ffmpeg"]["commit"],
        "ffmpeg_tag": SPEC["ffmpeg"]["version"],
        "ffmpeg_patches": SPEC["ffmpeg"].get("patches", {}),
        "configure": args,
        "libraries": libraries,
    }
    (prefix / "rillight-core-dependencies.json").write_text(
        json.dumps(marker, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    failures = verify(prefix, marker["platform"])
    if failures:
        raise RuntimeError("; ".join(failures))
    print(f"Built verified development SDK: {abi} -> {prefix}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix-root", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--ndk", type=Path, required=True)
    parser.add_argument("--source", type=Path,
                        help="reuse a patched locked source checkout")
    parser.add_argument("--bash", type=Path,
                        default=shutil.which("bash") or "C:/msys64/usr/bin/bash.exe")
    parser.add_argument("--abis", nargs="+", choices=ABIS,
                        default=list(ABIS))
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    prefix_root = args.prefix_root.resolve()
    work = args.work.resolve()
    ndk = args.ndk.resolve()
    bash = args.bash.resolve()
    source = args.source.resolve() if args.source else work / "ffmpeg"
    if not bash.is_file() or not (ndk / "toolchains/llvm/prebuilt").is_dir():
        parser.error("provide an installed Bash and Android NDK root")
    host = {"Windows": "windows-x86_64", "Linux": "linux-x86_64"}.get(platform.system())
    if host is None:
        parser.error("Android SDK builder currently supports Windows or Linux hosts")
    ndk_bin = ndk / "toolchains/llvm/prebuilt" / host / "bin"
    if not ndk_bin.is_dir():
        parser.error(f"NDK host toolchain is missing: {ndk_bin}")
    work.mkdir(parents=True, exist_ok=True)
    if args.source:
        verify_supplied_source(source)
    else:
        prepare_source(source)
        verify_supplied_source(source)
    for abi in args.abis:
        build_abi(
            abi=abi, prefix_root=prefix_root, work=work,
            source=source, ndk_bin=ndk_bin, bash=bash, jobs=args.jobs,
        )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Android core SDK build failed: {error}", file=sys.stderr)
        sys.exit(1)
