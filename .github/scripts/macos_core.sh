#!/usr/bin/env bash
# Provision the universal owned core; tags must supply pinned artifacts.
set -euo pipefail
names=(CORE_SDK_URL CORE_SDK_SHA256 CORE_DYLIB_URL CORE_DYLIB_SHA256)
provided=0
missing=()
for name in "${names[@]}"; do
  if [ -n "${!name:-}" ]; then
    provided=$((provided + 1))
  else
    missing+=("$name")
  fi
done
if [ "$provided" -eq 4 ]; then
  for name in CORE_SDK_SHA256 CORE_DYLIB_SHA256; do
    if ! [[ "${!name}" =~ ^[[:xdigit:]]{64}$ ]]; then
      echo "::error::$name must be a 64-character SHA256 digest" >&2
      exit 1
    fi
  done
  mode=prebuilt
elif [ "$provided" -eq 0 ] && [ "${ALLOW_SOURCE_BUILD:-false}" = true ] &&
     [[ "${GITHUB_REF:-}" != refs/tags/* ]]; then
  mode=source
else
  echo "::error::Missing pinned macOS core inputs: ${missing[*]}. Supply all four inputs; source builds are only allowed for non-release CI with no inputs." >&2
  exit 1
fi
if [ "${1:-}" = mode ]; then
  echo "$mode"
  exit 0
fi

sdk_prefix="${RUNNER_TEMP:?}/rillight-macos-sdk"
evidence="$PWD/build/macos-native-inputs"
mkdir -p "$sdk_prefix" "$evidence"
sdk_archive="$evidence/rillight-macos-sdk.tar.gz"
core_dylib="$evidence/librillight_core.dylib"
if [ "$mode" = source ]; then
  bash packages/rillight_player/native/build_macos.sh \
    "$sdk_prefix" "$RUNNER_TEMP/rillight-macos-sdk-work" 2>&1 | tee "$evidence/sdk-build.log"
  cmake -S packages/rillight_player/native -B build/macos-core \
    -DRILLIGHT_CORE_PREFIX="$sdk_prefix" \
    '-DCMAKE_OSX_ARCHITECTURES=x86_64;arm64' \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_BUILD_TYPE=Release \
    2>&1 | tee "$evidence/core-configure.log"
  cmake --build build/macos-core --config Release --target rillight_core --parallel 3 \
    2>&1 | tee "$evidence/core-build.log"
  cp build/macos-core/librillight_core.dylib "$core_dylib"
  tar -czf "$sdk_archive" -C "$sdk_prefix" .
else
  curl --fail --location --retry 3 "$CORE_SDK_URL" --output "$sdk_archive"
  curl --fail --location --retry 3 "$CORE_DYLIB_URL" --output "$core_dylib"
  echo "$CORE_SDK_SHA256  $sdk_archive" | shasum -a 256 --check
  echo "$CORE_DYLIB_SHA256  $core_dylib" | shasum -a 256 --check
  tar -xzf "$sdk_archive" -C "$sdk_prefix"
fi
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
  echo "provisioning=$mode"
  echo "candidate=$(git rev-parse HEAD)"
  echo "runner_arch=$(uname -m)"
  xcodebuild -version
  xcrun --sdk macosx --show-sdk-version
  cmake --version
} > "$evidence/build-context.txt"
cp "$sdk_prefix/rillight-core-dependencies.json" "$evidence/"
