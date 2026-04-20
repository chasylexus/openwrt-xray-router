#!/bin/sh
# cap-volatile-logs.sh
#
# Keep hot Xray/cron logs in /tmp bounded in size. This is intentionally
# copytruncate-style: Xray keeps file descriptors open, so rename-based
# rotation would not move future writes to the new path.

set -eu

XRAY_ROOT="/etc/xray"
STATE="$XRAY_ROOT/state"

# shellcheck disable=SC1091
[ -r "$XRAY_ROOT/secret.env" ] && . "$XRAY_ROOT/secret.env"

ACCESS_MAX="${XRAY_ACCESS_LOG_MAX_BYTES:-16777216}"
ACCESS_KEEP="${XRAY_ACCESS_LOG_KEEP_BYTES:-8388608}"
ERROR_MAX="${XRAY_ERROR_LOG_MAX_BYTES:-33554432}"
ERROR_KEEP="${XRAY_ERROR_LOG_KEEP_BYTES:-16777216}"
CRON_MAX="${XRAY_CRON_LOG_MAX_BYTES:-2097152}"
CRON_KEEP="${XRAY_CRON_LOG_KEEP_BYTES:-524288}"
TEST_MAX="${XRAY_TEST_LOG_MAX_BYTES:-524288}"
TEST_KEEP="${XRAY_TEST_LOG_KEEP_BYTES:-131072}"

WORK=$(mktemp -d "$STATE/logcap.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

log() {
    command -v logger >/dev/null 2>&1 || return 0
    logger -t xray-logcap "$*"
}

trim_log() {
    path="$1"
    max_bytes="$2"
    keep_bytes="$3"

    [ -e "$path" ] || return 0
    size=$(wc -c < "$path" | awk '{print $1}')
    [ "$size" -le "$max_bytes" ] && return 0

    base=$(basename "$path")
    tmp="$WORK/$base.tail"

    tail -c "$keep_bytes" "$path" > "$tmp"
    cat "$tmp" > "$path"

    new_size=$(wc -c < "$path" | awk '{print $1}')
    log "trimmed $path from ${size}B to ${new_size}B"
}

trim_log /tmp/xray-access.log "$ACCESS_MAX" "$ACCESS_KEEP"
trim_log /tmp/xray-error.log  "$ERROR_MAX"  "$ERROR_KEEP"
trim_log /tmp/xray-test.log   "$TEST_MAX"   "$TEST_KEEP"
trim_log /tmp/xray-cron.log   "$CRON_MAX"   "$CRON_KEEP"
