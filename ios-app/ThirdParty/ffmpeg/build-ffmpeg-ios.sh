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
mkdir -p "$WRAP_DIR" "$HEADER_DIR"
cat > "$HEADER_DIR/FFmpegRemux.h" <<'EOF_HEADER'
#ifndef FFmpegRemux_h
#define FFmpegRemux_h

#ifdef __cplusplus
extern "C" {
#endif

int ibili_remux_mp4(const char *video_path,
                    const char *audio_path,
                    const char *output_path,
                    char *error_buffer,
                    int error_buffer_size);

#ifdef __cplusplus
}
#endif

#endif
EOF_HEADER

cat > "$HEADER_DIR/module.modulemap" <<'EOF_MODULE'
framework module FFmpegRemux {
  umbrella header "FFmpegRemux.h"
  export *
  module * { export * }
}
EOF_MODULE

cat > "$WRAP_DIR/FFmpegRemux.c" <<'EOF_C'
#include "FFmpegRemux.h"
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/timestamp.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static void set_error(char *buffer, int buffer_size, const char *fmt, ...) {
    if (!buffer || buffer_size <= 0) return;
    va_list args;
    va_start(args, fmt);
    vsnprintf(buffer, (size_t)buffer_size, fmt, args);
    va_end(args);
}

static void set_av_error(char *buffer, int buffer_size, const char *context, int err) {
    char av_error[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(err, av_error, sizeof(av_error));
    set_error(buffer, buffer_size, "%s: %s (%d)", context, av_error, err);
}

static int open_input(const char *path, AVFormatContext **ctx, char *errbuf, int errbuf_size) {
    int ret = avformat_open_input(ctx, path, NULL, NULL);
    if (ret < 0) {
        set_av_error(errbuf, errbuf_size, "avformat_open_input", ret);
        return ret;
    }
    ret = avformat_find_stream_info(*ctx, NULL);
    if (ret < 0) {
        set_av_error(errbuf, errbuf_size, "avformat_find_stream_info", ret);
        return ret;
    }
    return 0;
}

static int find_stream(AVFormatContext *ctx, enum AVMediaType type) {
    for (unsigned int i = 0; i < ctx->nb_streams; i++) {
        if (ctx->streams[i]->codecpar->codec_type == type) return (int)i;
    }
    return -1;
}

int ibili_remux_mp4(const char *video_path,
                    const char *audio_path,
                    const char *output_path,
                    char *error_buffer,
                    int error_buffer_size) {
    AVFormatContext *video_ctx = NULL;
    AVFormatContext *audio_ctx = NULL;
    AVFormatContext *out_ctx = NULL;
    AVPacket *pkt = NULL;
    int ret = 0;
    int video_in_index = -1;
    int audio_in_index = -1;
    int video_out_index = -1;
    int audio_out_index = -1;

    if (!video_path || !output_path) {
        set_error(error_buffer, error_buffer_size, "video_path and output_path are required");
        return AVERROR(EINVAL);
    }

    ret = open_input(video_path, &video_ctx, error_buffer, error_buffer_size);
    if (ret < 0) goto cleanup;
    video_in_index = find_stream(video_ctx, AVMEDIA_TYPE_VIDEO);
    if (video_in_index < 0) {
        set_error(error_buffer, error_buffer_size, "no video stream");
        ret = AVERROR_STREAM_NOT_FOUND;
        goto cleanup;
    }

    if (audio_path && audio_path[0] != '\0') {
        ret = open_input(audio_path, &audio_ctx, error_buffer, error_buffer_size);
        if (ret < 0) goto cleanup;
        audio_in_index = find_stream(audio_ctx, AVMEDIA_TYPE_AUDIO);
        if (audio_in_index < 0) {
            set_error(error_buffer, error_buffer_size, "no audio stream");
            ret = AVERROR_STREAM_NOT_FOUND;
            goto cleanup;
        }
    }

    ret = avformat_alloc_output_context2(&out_ctx, NULL, "mp4", output_path);
    if (ret < 0 || !out_ctx) {
        set_av_error(error_buffer, error_buffer_size, "avformat_alloc_output_context2", ret);
        goto cleanup;
    }

    AVStream *video_in = video_ctx->streams[video_in_index];
    AVStream *video_out = avformat_new_stream(out_ctx, NULL);
    if (!video_out) {
        set_error(error_buffer, error_buffer_size, "avformat_new_stream video failed");
        ret = AVERROR(ENOMEM);
        goto cleanup;
    }
    video_out_index = video_out->index;
    ret = avcodec_parameters_copy(video_out->codecpar, video_in->codecpar);
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "avcodec_parameters_copy video", ret);
        goto cleanup;
    }
    video_out->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
    video_out->time_base = video_in->time_base;

    if (audio_ctx && audio_in_index >= 0) {
        AVStream *audio_in = audio_ctx->streams[audio_in_index];
        AVStream *audio_out = avformat_new_stream(out_ctx, NULL);
        if (!audio_out) {
            set_error(error_buffer, error_buffer_size, "avformat_new_stream audio failed");
            ret = AVERROR(ENOMEM);
            goto cleanup;
        }
        audio_out_index = audio_out->index;
        ret = avcodec_parameters_copy(audio_out->codecpar, audio_in->codecpar);
        if (ret < 0) {
            set_av_error(error_buffer, error_buffer_size, "avcodec_parameters_copy audio", ret);
            goto cleanup;
        }
        audio_out->codecpar->codec_tag = 0;
        audio_out->time_base = audio_in->time_base;
    }

    if (!(out_ctx->oformat->flags & AVFMT_NOFILE)) {
        ret = avio_open(&out_ctx->pb, output_path, AVIO_FLAG_WRITE);
        if (ret < 0) {
            set_av_error(error_buffer, error_buffer_size, "avio_open", ret);
            goto cleanup;
        }
    }

    AVDictionary *mux_opts = NULL;
    av_dict_set(&mux_opts, "movflags", "+faststart", 0);
    ret = avformat_write_header(out_ctx, &mux_opts);
    av_dict_free(&mux_opts);
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "avformat_write_header", ret);
        goto cleanup;
    }

    pkt = av_packet_alloc();
    if (!pkt) {
        set_error(error_buffer, error_buffer_size, "av_packet_alloc failed");
        ret = AVERROR(ENOMEM);
        goto cleanup;
    }

    while ((ret = av_read_frame(video_ctx, pkt)) >= 0) {
        if (pkt->stream_index == video_in_index) {
            pkt->stream_index = video_out_index;
            av_packet_rescale_ts(pkt, video_in->time_base, out_ctx->streams[video_out_index]->time_base);
            ret = av_interleaved_write_frame(out_ctx, pkt);
            av_packet_unref(pkt);
            if (ret < 0) {
                set_av_error(error_buffer, error_buffer_size, "av_interleaved_write_frame video", ret);
                goto cleanup;
            }
        } else {
            av_packet_unref(pkt);
        }
    }
    if (ret == AVERROR_EOF) ret = 0;
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "av_read_frame video", ret);
        goto cleanup;
    }

    if (audio_ctx && audio_in_index >= 0) {
        AVStream *audio_in = audio_ctx->streams[audio_in_index];
        while ((ret = av_read_frame(audio_ctx, pkt)) >= 0) {
            if (pkt->stream_index == audio_in_index) {
                pkt->stream_index = audio_out_index;
                av_packet_rescale_ts(pkt, audio_in->time_base, out_ctx->streams[audio_out_index]->time_base);
                ret = av_interleaved_write_frame(out_ctx, pkt);
                av_packet_unref(pkt);
                if (ret < 0) {
                    set_av_error(error_buffer, error_buffer_size, "av_interleaved_write_frame audio", ret);
                    goto cleanup;
                }
            } else {
                av_packet_unref(pkt);
            }
        }
        if (ret == AVERROR_EOF) ret = 0;
        if (ret < 0) {
            set_av_error(error_buffer, error_buffer_size, "av_read_frame audio", ret);
            goto cleanup;
        }
    }

    ret = av_write_trailer(out_ctx);
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "av_write_trailer", ret);
        goto cleanup;
    }

cleanup:
    if (pkt) av_packet_free(&pkt);
    if (out_ctx) {
        if (out_ctx->pb) avio_closep(&out_ctx->pb);
        avformat_free_context(out_ctx);
    }
    if (video_ctx) avformat_close_input(&video_ctx);
    if (audio_ctx) avformat_close_input(&audio_ctx);
    return ret;
}
EOF_C

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
