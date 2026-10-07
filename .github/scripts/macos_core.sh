#!/usr/bin/env bash
# Build the universal SDK from pinned sources and compile the candidate core.
set -euo pipefail

sdk_prefix="${RUNNER_TEMP:?}/rillight-macos-sdk"
evidence="$PWD/build/macos-native-inputs"
mkdir -p "$sdk_prefix" "$evidence"
sdk_archive="$evidence/rillight-macos-sdk.tar.gz"
core_dylib="$evidence/librillight_core.dylib"
bash packages/rillight_player/native/build_macos.sh \
  "$sdk_prefix" "$RUNNER_TEMP/rillight-macos-sdk-work" 2>&1 | tee "$evidence/sdk-build.log"
cmake -S packages/rillight_player/native -B build/macos-core \
  -DRILLIGHT_CORE_PREFIX="$sdk_prefix" \
  '-DCMAKE_OSX_ARCHITECTURES=x86_64;arm64' \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_BUILD_TYPE=Release \
  2>&1 | tee "$evidence/core-configure.log"
cmake --build build/macos-core --config Release --target rillight_core --parallel 3 \
  2>&1 | tee "$evidence/core-build.log"
# prepare_macos.py and the app bundle only read weights beside the published
# dylib. POST_BUILD writes RIFE, Real-ESRGAN and Anime4K next to the built
# library; copying the dylib alone drops that tree.
core_build="build/macos-core"
enhancement_files=(
  rife-v4.6/flownet.param
  rife-v4.6/flownet.bin
  realesr-general-x4v3.param
  realesr-general-x4v3.bin
  shaders/anime4k/Anime4K_Restore_CNN_M.glsl
  shaders/anime4k/Anime4K_Restore_CNN_VL.glsl
  shaders/anime4k/Anime4K_Upscale_CNN_x2_M.glsl
  shaders/anime4k/Anime4K_Upscale_CNN_x2_VL.glsl
)
for relative in "${enhancement_files[@]}"; do
  if [[ ! -f "$core_build/$relative" ]]; then
    echo "Pinned enhancement file missing beside built core: $relative" >&2
    exit 1
  fi
done
cp "$core_build/librillight_core.dylib" "$core_dylib"
rm -rf "$evidence/rife-v4.6" "$evidence/shaders" \
  "$evidence/realesr-general-x4v3.param" "$evidence/realesr-general-x4v3.bin"
cp -R "$core_build/rife-v4.6" "$evidence/rife-v4.6"
cp -R "$core_build/shaders" "$evidence/shaders"
cp "$core_build/realesr-general-x4v3.param" "$core_build/realesr-general-x4v3.bin" "$evidence/"
tar -czf "$sdk_archive" -C "$sdk_prefix" .
python3 packages/rillight_player/native/verify_core_dependencies.py \
  --prefix "$sdk_prefix" --target macos-universal --require-subtitles
export RILLIGHT_MACOS_CORE_PREFIX="$sdk_prefix"
export RILLIGHT_MACOS_CORE_DYLIB="$core_dylib"
RILLIGHT_MACOS_CORE_SHA256="$(shasum -a 256 "$core_dylib" | awk '{print $1}')"
export RILLIGHT_MACOS_CORE_SHA256
# Also verifies the core hash and both slices before publishing the environment.
python3 packages/rillight_player/native/prepare_macos.py
{
  echo "RILLIGHT_MACOS_CORE_PREFIX=$sdk_prefix"
  echo "RILLIGHT_MACOS_CORE_DYLIB=$core_dylib"
  echo "RILLIGHT_MACOS_CORE_SHA256=$RILLIGHT_MACOS_CORE_SHA256"
} >> "${GITHUB_ENV:?}"
(
  cd "$evidence"
  shasum -a 256 rillight-macos-sdk.tar.gz librillight_core.dylib > SHA256SUMS
)
{
  echo 'provisioning=source'
  echo "candidate=$(git rev-parse HEAD)"
  echo "runner_arch=$(uname -m)"
  xcodebuild -version
  xcrun --sdk macosx --show-sdk-version
  cmake --version
} > "$evidence/build-context.txt"
cp "$sdk_prefix/rillight-core-dependencies.json" "$evidence/"
