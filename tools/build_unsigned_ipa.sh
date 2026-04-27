#!/usr/bin/env bash
# Build an unsigned IPA of the Ibili app.
#
# Pipeline:
#   1. cargo build → IbiliCore.xcframework (device-only by default)
#   2. xcodegen generate → ios-app/Ibili.xcodeproj
#   3. xcodebuild archive (CODE_SIGNING_ALLOWED=NO)
#   4. Manual Payload/<App>.app → zip → dist/Ibili-unsigned.ipa
#
# Output: dist/Ibili-unsigned.ipa
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="Ibili"
PROJECT="ios-app/Ibili.xcodeproj"
ARCHIVE="$ROOT/build/Ibili.xcarchive"
DIST_DIR="$ROOT/dist"
IPA="$DIST_DIR/Ibili-unsigned.ipa"

# 1. Rust core
echo "==> step 1/4  building Rust XCFramework"
bash "$ROOT/tools/build_rust_xcframework.sh"

# 2. Project generation
echo "==> step 2/4  generating Xcode project"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found; install via 'brew install xcodegen'." >&2
  exit 3
fi
( cd ios-app && xcodegen generate --quiet )

# 3. Archive (no codesign)
echo "==> step 3/4  xcodebuild archive (unsigned)"
rm -rf "$ARCHIVE"
XCB_LOG="$ROOT/build/xcodebuild-archive.log"
mkdir -p "$ROOT/build"
set +e
if command -v xcpretty >/dev/null 2>&1; then
  xcodebuild \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination "generic/platform=iOS" -archivePath "$ARCHIVE" \
    -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_ENTITLEMENTS="" EXPANDED_CODE_SIGN_IDENTITY="" \
    archive | tee "$XCB_LOG" | xcpretty --color
  XCB_RC=${PIPESTATUS[0]}
else
  xcodebuild \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination "generic/platform=iOS" -archivePath "$ARCHIVE" \
    -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_ENTITLEMENTS="" EXPANDED_CODE_SIGN_IDENTITY="" \
    archive 2>&1 | tee "$XCB_LOG" | grep -E "^(=== |\\*\\* |error:|warning:|note:|/.*: error:|.*\\.swift:.*error)" || true
  XCB_RC=${PIPESTATUS[0]}
fi
set -e

if [[ ! -d "$ARCHIVE/Products/Applications" ]]; then
  echo "archive failed (rc=$XCB_RC): no Applications/ in $ARCHIVE" >&2
  echo "see full log: $XCB_LOG" >&2
  exit 4
fi

# 4. Repackage as IPA
echo "==> step 4/4  packaging unsigned IPA"
mkdir -p "$DIST_DIR"
PAYLOAD="$ROOT/build/Payload"
rm -rf "$PAYLOAD" "$IPA"
mkdir -p "$PAYLOAD"
cp -R "$ARCHIVE/Products/Applications/"*.app "$PAYLOAD/"

( cd "$ROOT/build" && zip -qr "$IPA" Payload )
rm -rf "$PAYLOAD"

echo ""
echo "================================================================="
echo "  unsigned IPA: $IPA"
echo "  size: $(du -h "$IPA" | cut -f1)"
echo "================================================================="
