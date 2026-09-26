"""Rebuild the owned Windows DLL from a pinned, verified FFmpeg/libass SDK.

The input SDK must already contain the locked FFmpeg/libass headers, import
libraries and runtime DLLs. This script does not accept an mpv distribution.
"""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess

from verify_core_dependencies import verify


NATIVE = Path(__file__).resolve().parent


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--mingw-bin", type=Path, default=Path("C:/msys64/mingw64/bin"))
    args = parser.parse_args()
    if platform.system() != "Windows":
        parser.error("the Windows core must be built and loaded on Windows")
    prefix, build, toolchain = args.prefix.resolve(), args.build.resolve(), args.mingw_bin.resolve()
    if prefix == build or prefix in build.parents or build in prefix.parents:
        parser.error("SDK prefix and build directory must be separate")
    errors = verify(prefix, "windows-x64", require_subtitles=True)
    if errors:
        parser.error("Invalid pinned input SDK: " + "; ".join(errors))
    cmake, compiler, ninja = (toolchain / name for name in
                              ("cmake.exe", "c++.exe", "ninja.exe"))
    if not all(path.is_file() for path in (cmake, compiler, ninja)):
        parser.error(f"Missing MinGW64 CMake, g++ or Ninja in {toolchain}")
    env = dict(os.environ)
    env["PATH"] = str(toolchain) + os.pathsep + env.get("PATH", "")
    subprocess.run([str(cmake), "-S", str(NATIVE), "-B", str(build),
                    "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
                    f"-DCMAKE_CXX_COMPILER={compiler}",
                    f"-DRILLIGHT_CORE_PREFIX={prefix}"], env=env, check=True)
    subprocess.run([str(cmake), "--build", str(build), "--target", "rillight_core",
                    "-j", str(max(1, os.cpu_count() or 2))], env=env, check=True)
    built = build / "librillight_core.dll"
    if not built.is_file():
        raise RuntimeError(f"No built core DLL: {built}")
    published = prefix / "bin/librillight_core.dll"
    temporary = published.with_suffix(".dll.new")
    shutil.copyfile(built, temporary)
    os.replace(temporary, published)
    marker_file = prefix / "rillight-core-dependencies.json"
    marker = json.loads(marker_file.read_text(encoding="utf-8"))
    marker["libraries"]["bin/librillight_core.dll"] = digest(published)
    marker_file.write_text(json.dumps(marker, indent=2, sort_keys=True) + "\n",
                           encoding="utf-8")
    errors = verify(prefix, "windows-x64", require_subtitles=True)
    if errors:
        raise RuntimeError("Published SDK failed hash verification: " + "; ".join(errors))
    with os.add_dll_directory(str(prefix / "bin")):
        library = ctypes.WinDLL(str(published))
        library.rillight_core_abi_version.restype = ctypes.c_uint32
        library.rillight_core_ffmpeg_versions.restype = ctypes.c_char_p
        abi = library.rillight_core_abi_version()
        versions = library.rillight_core_ffmpeg_versions().decode("ascii")
    header = (NATIVE / "core/rillight_core.h").read_text()
    expected_abi = int(re.search(r"#define RILLIGHT_CORE_ABI_VERSION (\d+)", header).group(1))
    if abi != expected_abi or not versions.startswith("ffmpeg=9.0.1;"):
        raise RuntimeError(f"Built core runtime mismatch: ABI {abi}, {versions}")
    print(json.dumps({"coreAbi": abi, "versions": versions,
                      "sha256": digest(published)}, sort_keys=True))


if __name__ == "__main__":
    main()
