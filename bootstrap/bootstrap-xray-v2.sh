#!/bin/sh
# Compatibility entrypoint for older notes/links.
# The active router stack is TrustTunnel + sing-box.

set -eu

REPO_RAW="${REPO_RAW:-}"

if [ -r "./bootstrap/bootstrap-sing-box-router.sh" ]; then
    exec sh "./bootstrap/bootstrap-sing-box-router.sh" "$@"
fi

[ -n "$REPO_RAW" ] || {
    echo "set REPO_RAW to the raw repository base URL" >&2
    exit 1
}

tmp="/tmp/bootstrap-sing-box-router.$$"
if command -v curl >/dev/null 2>&1; then
    curl -4 -fsSL -o "$tmp" "$REPO_RAW/bootstrap/bootstrap-sing-box-router.sh"
elif command -v wget >/dev/null 2>&1; then
    wget -4 -q -O "$tmp" "$REPO_RAW/bootstrap/bootstrap-sing-box-router.sh"
elif command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -4 -O "$tmp" "$REPO_RAW/bootstrap/bootstrap-sing-box-router.sh"
else
    echo "no downloader found; install curl or wget" >&2
    exit 1
fi

exec sh "$tmp" "$@"
