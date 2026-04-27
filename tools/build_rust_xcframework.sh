#!/usr/bin/env bash
# Build IbiliCore.xcframework from the Rust workspace.
# Output: ios-app/Frameworks/IbiliCore.xcframework
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE_DIR="$ROOT/core/rust"
CRATE_NAME="ibili_ffi"
LIB_BASENAME="libibili_ffi.a"
OUT_DIR="$ROOT/ios-app/Frameworks"
XCF="$OUT_DIR/IbiliCore.xcframework"
HEADERS_SRC="$CRATE_DIR/crates/ibili_ffi/include"

# Default to device-only to keep IPA build simple; pass --with-sim for both.
WITH_SIM=0
for arg in "$@"; do
  case "$arg" in
    --with-sim) WITH_SIM=1 ;;
    --device-only) WITH_SIM=0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

echo "[rust] ensuring iOS targets installed"
rustup target add aarch64-apple-ios >/dev/null
if [[ $WITH_SIM -eq 1 ]]; then
  rustup target add aarch64-apple-ios-sim x86_64-apple-ios >/dev/null
fi

pushd "$CRATE_DIR" >/dev/null

echo "[rust] building aarch64-apple-ios (device)"
cargo build -p "$CRATE_NAME" --release --target aarch64-apple-ios

if [[ $WITH_SIM -eq 1 ]]; then
  echo "[rust] building simulators"
  cargo build -p "$CRATE_NAME" --release --target aarch64-apple-ios-sim
  cargo build -p "$CRATE_NAME" --release --target x86_64-apple-ios
fi

popd >/dev/null

DEVICE_LIB="$CRATE_DIR/target/aarch64-apple-ios/release/$LIB_BASENAME"
SIM_DIR_TMP="$ROOT/build/sim_universal"

rm -rf "$XCF"
mkdir -p "$OUT_DIR"

# Stage headers (umbrella header + modulemap) into a directory we hand to xcodebuild.
HEADER_STAGE="$ROOT/build/ibili_headers"
rm -rf "$HEADER_STAGE"
mkdir -p "$HEADER_STAGE"
cp "$HEADERS_SRC/ibili.h" "$HEADER_STAGE/"
cp "$HEADERS_SRC/module.modulemap" "$HEADER_STAGE/"

if [[ $WITH_SIM -eq 1 ]]; then
  rm -rf "$SIM_DIR_TMP"
  mkdir -p "$SIM_DIR_TMP"
  lipo -create \
    "$CRATE_DIR/target/aarch64-apple-ios-sim/release/$LIB_BASENAME" \
    "$CRATE_DIR/target/x86_64-apple-ios/release/$LIB_BASENAME" \
    -output "$SIM_DIR_TMP/$LIB_BASENAME"

  xcodebuild -create-xcframework \
    -library "$DEVICE_LIB" -headers "$HEADER_STAGE" \
    -library "$SIM_DIR_TMP/$LIB_BASENAME" -headers "$HEADER_STAGE" \
    -output "$XCF"
else
  xcodebuild -create-xcframework \
    -library "$DEVICE_LIB" -headers "$HEADER_STAGE" \
    -output "$XCF"
fi

echo "[ok] wrote $XCF"
