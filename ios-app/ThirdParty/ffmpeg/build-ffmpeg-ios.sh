#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WORK_DIR="$ROOT_DIR/ThirdParty/ffmpeg/build"
SRC_DIR="$WORK_DIR/src"
OUT_DIR="$WORK_DIR/out"
FRAMEWORKS_DIR="$ROOT_DIR/Frameworks"
FFMPEG_VERSION="${FFMPEG_VERSION:-7.1.1}"
FFMPEG_URLS=(
  "${FFMPEG_URL:-https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz}"
  "${FFMPEG_FALLBACK_URL:-https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz}"
  "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${FFMPEG_VERSION}.tar.gz"
)

IOS_MIN_VERSION="${IOS_MIN_VERSION:-16.0}"
IOS_ARCHS=("arm64")
SIM_ARCHS=("arm64")
BUILD_JOBS="${BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

usage() {
  cat <<USAGE
Usage: $0 [--version <ffmpeg-version>] [--clean]

Builds a minimal LGPL FFmpegRemux.xcframework for iOS.
Environment overrides:
  FFMPEG_VERSION   default: ${FFMPEG_VERSION}
  IOS_MIN_VERSION  default: ${IOS_MIN_VERSION}
USAGE
}

CLEAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      FFMPEG_VERSION="$2"
      FFMPEG_URLS=(
        "${FFMPEG_URL:-https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz}"
        "${FFMPEG_FALLBACK_URL:-https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz}"
        "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${FFMPEG_VERSION}.tar.gz"
      )
      shift 2
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$CLEAN" == "1" ]]; then
  rm -rf "$WORK_DIR" "$FRAMEWORKS_DIR/FFmpegRemux.xcframework"
fi

mkdir -p "$SRC_DIR" "$OUT_DIR" "$FRAMEWORKS_DIR"

TARBALL="$SRC_DIR/ffmpeg-${FFMPEG_VERSION}.tar"
SOURCE="$SRC_DIR/ffmpeg-${FFMPEG_VERSION}"
if [[ ! -f "$TARBALL" ]]; then
  for existing in \
    "$SRC_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
    "$SRC_DIR/ffmpeg-${FFMPEG_VERSION}.tar.gz" \
    "$SRC_DIR/n${FFMPEG_VERSION}.tar.gz"; do
    if [[ -f "$existing" ]]; then
      cp "$existing" "$TARBALL"
      break
    fi
  done
fi
if [[ ! -f "$TARBALL" ]]; then
  download_ok=0
  for url in "${FFMPEG_URLS[@]}"; do
    echo "Downloading FFmpeg from $url"
    if curl --fail --location --retry 2 --connect-timeout 20 \
      --user-agent "Mozilla/5.0 ibili-ffmpeg-builder" \
      "$url" -o "$TARBALL"; then
      download_ok=1
      break
    fi
  done
  if [[ "$download_ok" != "1" ]]; then
    echo "Failed to download FFmpeg source." >&2
    echo "You can manually place one of these files under $SRC_DIR and rerun:" >&2
    echo "  ffmpeg-${FFMPEG_VERSION}.tar.xz" >&2
    echo "  ffmpeg-${FFMPEG_VERSION}.tar.gz" >&2
    echo "  n${FFMPEG_VERSION}.tar.gz" >&2
    exit 1
  fi
fi
if [[ ! -d "$SOURCE" ]]; then
  tar -xf "$TARBALL" -C "$SRC_DIR"
  if [[ -d "$SRC_DIR/FFmpeg-n${FFMPEG_VERSION}" && ! -d "$SOURCE" ]]; then
    mv "$SRC_DIR/FFmpeg-n${FFMPEG_VERSION}" "$SOURCE"
  fi
fi

SDK_PATH() {
  xcrun --sdk "$1" --show-sdk-path
}

CLANG_PATH() {
  xcrun --sdk "$1" --find clang
}

COMMON_CONFIG=(
  --disable-programs
  --disable-doc
  --disable-debug
  --disable-network
  --disable-avdevice
  --disable-avfilter
  --disable-swscale
  --disable-swresample
  --disable-postproc
  --disable-encoders
  --disable-decoders
  --disable-filters
  --disable-devices
  --disable-protocols
  --enable-protocol=file
  --disable-demuxers
  --enable-demuxer=mov
  --disable-muxers
  --enable-muxer=mp4
  --enable-muxer=mov
  --enable-muxer=hls
  --disable-parsers
  --enable-parser=hevc
  --enable-parser=aac
  --disable-bsfs
  --enable-bsf=aac_adtstoasc
  --enable-bsf=hevc_mp4toannexb
  --enable-pic
  --enable-static
  --disable-shared
  --disable-gpl
  --disable-nonfree
)

build_one() {
  local platform="$1"
  local arch="$2"
  local sdk="$3"
  local build_dir="$WORK_DIR/${platform}-${arch}"
  local prefix="$OUT_DIR/${platform}-${arch}"
  local sdk_path clang cflags ldflags host
  sdk_path="$(SDK_PATH "$sdk")"
  clang="$(CLANG_PATH "$sdk")"
  cflags="-arch ${arch} -isysroot ${sdk_path} -miphoneos-version-min=${IOS_MIN_VERSION} -fembed-bitcode=off"
  ldflags="-arch ${arch} -isysroot ${sdk_path} -miphoneos-version-min=${IOS_MIN_VERSION}"
  host="aarch64-apple-darwin"
  if [[ "$platform" == "simulator" ]]; then
    cflags="-arch ${arch} -isysroot ${sdk_path} -mios-simulator-version-min=${IOS_MIN_VERSION}"
    ldflags="-arch ${arch} -isysroot ${sdk_path} -mios-simulator-version-min=${IOS_MIN_VERSION}"
  fi

  rm -rf "$build_dir" "$prefix"
  mkdir -p "$build_dir" "$prefix"
  pushd "$build_dir" >/dev/null
  "$SOURCE/configure" \
    --prefix="$prefix" \
    --target-os=darwin \
    --arch="$arch" \
    --cc="$clang" \
    --enable-cross-compile \
    --sysroot="$sdk_path" \
    --extra-cflags="$cflags" \
    --extra-ldflags="$ldflags" \
    "${COMMON_CONFIG[@]}"
  make -j"$BUILD_JOBS"
  make install
  popd >/dev/null
}

for arch in "${IOS_ARCHS[@]}"; do
  build_one ios "$arch" iphoneos
done
for arch in "${SIM_ARCHS[@]}"; do
  build_one simulator "$arch" iphonesimulator
done

WRAP_DIR="$WORK_DIR/wrapper"
HEADER_DIR="$WRAP_DIR/Headers"
TRACKED_WRAP_DIR="$ROOT_DIR/ThirdParty/ffmpeg/wrapper"
mkdir -p "$WRAP_DIR" "$HEADER_DIR"

# Copy tracked wrapper source into the build tree.
cp "$TRACKED_WRAP_DIR/FFmpegRemux.c" "$WRAP_DIR/FFmpegRemux.c"
cp "$TRACKED_WRAP_DIR/Headers/FFmpegRemux.h" "$HEADER_DIR/FFmpegRemux.h"
cp "$TRACKED_WRAP_DIR/Headers/module.modulemap" "$HEADER_DIR/module.modulemap"

build_wrapper_one() {
  local platform="$1"
  local arch="$2"
  local sdk="$3"
  local prefix="$OUT_DIR/${platform}-${arch}"
  local wrapper_out="$OUT_DIR/wrapper-${platform}-${arch}"
  local sdk_path clang cflags
  sdk_path="$(SDK_PATH "$sdk")"
  clang="$(CLANG_PATH "$sdk")"
  cflags="-arch ${arch} -isysroot ${sdk_path} -miphoneos-version-min=${IOS_MIN_VERSION}"
  if [[ "$platform" == "simulator" ]]; then
    cflags="-arch ${arch} -isysroot ${sdk_path} -mios-simulator-version-min=${IOS_MIN_VERSION}"
  fi
  mkdir -p "$wrapper_out"
  "$clang" $cflags -I"$HEADER_DIR" -I"$prefix/include" -c "$WRAP_DIR/FFmpegRemux.c" -o "$wrapper_out/FFmpegRemux.o"
  libtool -static -o "$wrapper_out/libFFmpegRemux.a" \
    "$wrapper_out/FFmpegRemux.o" \
    "$prefix/lib/libavformat.a" \
    "$prefix/lib/libavcodec.a" \
    "$prefix/lib/libavutil.a"
}

build_wrapper_one ios arm64 iphoneos
build_wrapper_one simulator arm64 iphonesimulator

make_static_framework() {
  local platform="$1"
  local wrapper_out="$OUT_DIR/wrapper-${platform}-arm64"
  local framework_root="$OUT_DIR/framework-${platform}-arm64/FFmpegRemux.framework"
  rm -rf "$framework_root"
  mkdir -p "$framework_root/Headers" "$framework_root/Modules"
  cp "$wrapper_out/libFFmpegRemux.a" "$framework_root/FFmpegRemux"
  cp "$HEADER_DIR/FFmpegRemux.h" "$framework_root/Headers/FFmpegRemux.h"
  cp "$HEADER_DIR/module.modulemap" "$framework_root/Modules/module.modulemap"
  cat > "$framework_root/Info.plist" <<'EOF_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundlePackageType</key><string>FMWK</string><key>CFBundleIdentifier</key><string>app.ibili.FFmpegRemux</string><key>CFBundleName</key><string>FFmpegRemux</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0</string></dict></plist>
EOF_PLIST
}

make_static_framework ios
make_static_framework simulator

rm -rf "$FRAMEWORKS_DIR/FFmpegRemux.xcframework"
xcodebuild -create-xcframework \
  -framework "$OUT_DIR/framework-ios-arm64/FFmpegRemux.framework" \
  -framework "$OUT_DIR/framework-simulator-arm64/FFmpegRemux.framework" \
  -output "$FRAMEWORKS_DIR/FFmpegRemux.xcframework"

echo "Built $FRAMEWORKS_DIR/FFmpegRemux.xcframework"
