#!/usr/bin/env bash
# Build the pinned universal FFmpeg/libass/dav1d SDK for the owned macOS core.
set -euo pipefail
prefix="${1:?Usage: build_macos.sh ABSOLUTE_PREFIX [ABSOLUTE_WORK_DIR]}"
case "$prefix" in /*) ;; *) echo 'prefix must be absolute' >&2; exit 2;; esac
work="${2:-$prefix/../rillight-macos-source}"
case "$work" in /*) ;; *) echo 'work directory must be absolute' >&2; exit 2;; esac
script_dir="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$prefix" "$work"
prefix="$(cd "$prefix" && pwd)"
work="$(cd "$work" && pwd)"
if python3 "$script_dir/verify_core_dependencies.py" \
    --prefix "$prefix" --target macos-universal --require-subtitles; then
  echo "Using verified pinned macOS core SDK from $prefix"
  exit 0
fi
for command in git clang clang++ make nasm pkg-config python3 cmake lipo \
               install_name_tool otool; do
  command -v "$command" >/dev/null || { echo "Missing $command" >&2; exit 1; }
done
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install 'meson==1.7.2' 'ninja==1.11.1.4'
"$work/venv/bin/python" "$script_dir/build_macos_core_dependencies.py" \
  --prefix "$prefix" --work "$work" --with-libass
python3 "$script_dir/verify_core_dependencies.py" \
  --prefix "$prefix" --target macos-universal --require-subtitles
echo "Set RILLIGHT_MACOS_CORE_PREFIX=$prefix before building librillight_core.dylib."
