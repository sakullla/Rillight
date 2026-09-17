#!/usr/bin/env bash
# Fixed source build for Ubuntu 22.04+; no root writes. See README prerequisites.
set -euo pipefail
prefix="${1:?Usage: build_linux.sh ABSOLUTE_PREFIX [ABSOLUTE_BUILD_DIR]}"
case "$prefix" in /*) ;; *) echo 'prefix must be absolute' >&2; exit 2;; esac
work="${2:-$prefix/../rillight-mpv-source}"
mkdir -p "$prefix" "$work"
prefix="$(cd "$prefix" && pwd)"
work="$(cd "$work" && pwd)"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$prefix/lib:${LD_LIBRARY_PATH:-}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
if pkg-config --atleast-version=2.5.0 mpv && python3 "$script_dir/check_mpv.py" "$(pkg-config --variable=libdir mpv)/libmpv.so.2"; then
  echo "Using verified mpv >= 0.41.0 from $(pkg-config --variable=libdir mpv)"
  exit 0
fi
for command in git cc c++ make nasm pkg-config python3; do command -v "$command" >/dev/null; done
pkg-config --exists libass gnutls aom egl gl alsa libpulse
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install 'meson==1.7.2' 'ninja==1.11.1.4' 'Jinja2==3.1.6'
export PATH="$work/venv/bin:$PATH"
fetch() {
  local name="$1" url="$2" commit="$3"
  if [ ! -d "$work/$name/.git" ]; then
    git init "$work/$name"
    git -C "$work/$name" remote add origin "$url"
  fi
  git -C "$work/$name" fetch --depth=1 origin "$commit"
  git -C "$work/$name" checkout --detach FETCH_HEAD
  test "$(git -C "$work/$name" rev-parse HEAD)" = "$commit"
}
fetch ffmpeg https://github.com/FFmpeg/FFmpeg.git 894da5ca7d742e4429ffb2af534fcda0103ef593
fetch libplacebo https://github.com/haasn/libplacebo.git 3188549fba13bbdf3a5a98de2a38c2e71f04e21e
fetch mpv https://github.com/mpv-player/mpv.git 41f6a645068483470267271e1d09966ca3b9f413
git -C "$work/libplacebo" submodule update --init --depth=1 3rdparty/glad 3rdparty/jinja 3rdparty/markupsafe 3rdparty/fast_float
jobs="${RILLIGHT_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
(
  cd "$work/ffmpeg"
  ./configure --prefix="$prefix" --libdir="$prefix/lib" --enable-shared --disable-static --disable-programs --disable-doc --enable-gpl --enable-gnutls --enable-libass --enable-libaom --enable-vaapi --enable-pic
  make -j"$jobs"
  make install
)
meson setup "$work/libplacebo-build" "$work/libplacebo" --prefix="$prefix" --libdir=lib --buildtype=release -Ddefault_library=shared -Ddemos=false -Dtests=false -Dvulkan=disabled -Dshaderc=disabled -Dglslang=disabled -Dopengl=enabled -Dlibdovi=disabled
meson compile -C "$work/libplacebo-build" -j "$jobs"
meson install -C "$work/libplacebo-build"
meson setup "$work/mpv-build" "$work/mpv" --prefix="$prefix" --libdir=lib --buildtype=release -Dlibmpv=true -Dcplayer=false -Dtests=false -Dgl=enabled -Dvulkan=disabled -Dlua=disabled -Djavascript=disabled
meson compile -C "$work/mpv-build" -j "$jobs"
meson install -C "$work/mpv-build"
pkg-config --atleast-version=2.5.0 mpv
python3 "$script_dir/check_mpv.py" "$prefix/lib/libmpv.so.2"
printf 'mpv=0.41.0\nclient_api=%s\nffmpeg=n8.0.1\nlibplacebo=v7.351.0\n' "$(pkg-config --modversion mpv)" > "$prefix/rillight-source-versions.txt"
echo "Use PKG_CONFIG_PATH=$prefix/lib/pkgconfig and LD_LIBRARY_PATH=$prefix/lib for Flutter build and tests."
