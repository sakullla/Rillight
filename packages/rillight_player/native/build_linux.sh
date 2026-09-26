#!/usr/bin/env bash
# Build the pinned FFmpeg/libass SDK for the owned Linux core, without mpv.
set -euo pipefail
prefix="${1:?Usage: build_linux.sh ABSOLUTE_PREFIX [ABSOLUTE_WORK_DIR]}"
case "$prefix" in /*) ;; *) echo 'prefix must be absolute' >&2; exit 2;; esac
work="${2:-$prefix/../rillight-core-source}"
case "$work" in /*) ;; *) echo 'work directory must be absolute' >&2; exit 2;; esac
script_dir="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$prefix" "$work"
prefix="$(cd "$prefix" && pwd)"
work="$(cd "$work" && pwd)"
if python3 "$script_dir/verify_core_dependencies.py" \
    --prefix "$prefix" --target linux-x64 --require-subtitles; then
  echo "Using verified pinned core SDK from $prefix"
  exit 0
fi
for command in git cc c++ make nasm pkg-config python3; do
  command -v "$command" >/dev/null || { echo "Missing $command" >&2; exit 1; }
done
for package in libva libva-drm libdrm freetype2 fribidi harfbuzz fontconfig; do
  pkg-config --exists "$package" || { echo "Missing $package development package" >&2; exit 1; }
done
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install 'meson==1.7.2' 'ninja==1.11.1.4'
"$work/venv/bin/python" "$script_dir/build_core_dependencies.py" \
  --prefix "$prefix" --work "$work" --with-libass
"$work/venv/bin/python" "$script_dir/verify_core_dependencies.py" \
  --prefix "$prefix" --target linux-x64 --require-subtitles
echo "Set RILLIGHT_CORE_PREFIX=$prefix for Flutter Linux builds."
