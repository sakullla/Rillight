"""Bundle only the verified FFmpeg/libass SDK used by the owned Linux core.

Usage: python3 bundle_linux.py PREFIX BUNDLE
System GL, audio and font libraries remain distribution prerequisites.
"""

import hashlib
import json
from pathlib import Path
import shutil
import sys

from verify_core_dependencies import verify


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def bundle(prefix: Path, output: Path) -> None:
    prefix, output = prefix.resolve(), output.resolve()
    errors = verify(prefix, "linux-x64", require_subtitles=True)
    if errors:
        raise RuntimeError("Invalid pinned Linux SDK:\n" + "\n".join(errors))
    marker = json.loads((prefix / "rillight-core-dependencies.json").read_text())
    destination = output / "lib"
    destination.mkdir(parents=True, exist_ok=True)
    selected = dict(marker["libraries"])
    selected[marker["libass"]["library"]] = marker["libass"]["sha256"]
    selected[marker["dav1d"]["library"]] = marker["dav1d"]["sha256"]
    for relative, expected in selected.items():
        source = (prefix / relative).resolve()
        if prefix not in source.parents or digest(source) != expected:
            raise RuntimeError(f"SDK library changed or escaped prefix: {relative}")
        shutil.copyfile(source, destination / source.name)
    # Include only SONAME aliases resolving to a verified selected library.
    copied = {str((prefix / name).resolve()) for name in selected}
    for alias in (prefix / "lib").glob("*.so*"):
        if alias.is_symlink() and str(alias.resolve()) in copied:
            destination.joinpath(alias.name).symlink_to(alias.resolve().name)
    notices = output / "data/rillight_player"
    notices.mkdir(parents=True, exist_ok=True)
    native = Path(__file__).resolve().parent
    shutil.copyfile(native / "core_dependencies.json", notices / "core_dependencies.json")
    shutil.copyfile(prefix / "rillight-core-dependencies.json",
                    notices / "rillight-core-dependencies.json")
    shutil.copyfile(native.parent / "THIRD_PARTY_NOTICES.md",
                    notices / "THIRD_PARTY_NOTICES.md")
    shutil.copytree(native / "licenses", notices / "licenses", dirs_exist_ok=True)
    print(f"Bundled {len(selected)} verified core dependency libraries into {destination}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: bundle_linux.py PREFIX BUNDLE")
    bundle(Path(sys.argv[1]), Path(sys.argv[2]))
