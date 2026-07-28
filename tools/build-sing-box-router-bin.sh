#!/bin/sh

set -eu

OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.5}"
TARGET="${TARGET:-rockchip}"
SUBTARGET="${SUBTARGET:-armv8}"
SDK_FILE="openwrt-${OPENWRT_VERSION}-sdk-${TARGET}-${SUBTARGET}_gcc-14.3.0_musl.Linux-x86_64.tar.zst"
SDK_SHA256="59194a023968398af64bfa7d8bc3eac322641f6dc9cdbade28a4d9dd41866eba"
SDK_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${TARGET}/${SUBTARGET}/${SDK_FILE}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="$REPO_ROOT/.cache"
DOWNLOAD_DIR="$CACHE_DIR/downloads"
OUTPUT_DIR="$REPO_ROOT/dist/openwrt-${OPENWRT_VERSION}-${TARGET}-${SUBTARGET}"
LOG_FILE="$CACHE_DIR/sing-box-router-bin-build.log"

mkdir -p "$DOWNLOAD_DIR" "$OUTPUT_DIR"

printf 'Building sing-box-router-bin for OpenWrt %s %s/%s\n' \
    "$OPENWRT_VERSION" "$TARGET" "$SUBTARGET"
printf 'Verbose log: %s\n' "$LOG_FILE"

set +e
docker run --rm --platform linux/amd64 \
    -e SDK_FILE="$SDK_FILE" \
    -e SDK_SHA256="$SDK_SHA256" \
    -e SDK_URL="$SDK_URL" \
    -v "$REPO_ROOT:/repo:ro" \
    -v "$DOWNLOAD_DIR:/downloads" \
    -v "$OUTPUT_DIR:/output" \
    debian:bookworm-slim sh -c '
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl file gawk gettext git \
    libncurses-dev libssl-dev perl python3 rsync unzip zlib1g-dev zstd

if [ ! -f "/downloads/$SDK_FILE" ]; then
    curl -fL "$SDK_URL" -o "/downloads/$SDK_FILE"
fi
printf "%s  %s\n" "$SDK_SHA256" "/downloads/$SDK_FILE" | sha256sum -c -

mkdir -p /build
tar --zstd -xf "/downloads/$SDK_FILE" -C /build
sdk_dir="$(find /build -mindepth 1 -maxdepth 1 -type d -name "openwrt-sdk-*" -print -quit)"
[ -n "$sdk_dir" ]

cp -a /repo/package/sing-box-router-bin "$sdk_dir/package/"
cd "$sdk_dir"
printf "%s\n" "CONFIG_PACKAGE_sing-box-router-bin=y" >.config
make defconfig
make package/sing-box-router-bin/download
make package/sing-box-router-bin/compile V=s

artifact="$(find bin/packages -type f -name "sing-box-router-bin-*.apk" -print -quit)"
[ -n "$artifact" ]
cp "$artifact" /output/
' >"$LOG_FILE" 2>&1
status=$?
set -e

if [ "$status" -ne 0 ]; then
    printf 'Build failed (exit %s). Last log lines:\n' "$status" >&2
    tail -n 160 "$LOG_FILE" >&2
    exit "$status"
fi

artifact="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name 'sing-box-router-bin-*.apk' -print -quit)"
[ -n "$artifact" ] || {
    printf 'Build completed but no APK was copied; see %s\n' "$LOG_FILE" >&2
    exit 1
}

shasum -a 256 "$artifact" >"$artifact.sha256"
printf 'Built: %s\n' "$artifact"
cat "$artifact.sha256"
