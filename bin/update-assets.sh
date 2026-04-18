#!/bin/sh
# update-assets.sh
#
# Download fresh geosite.dat / geoip.dat (and optionally a custom geosite file)
# into a temp dir, validate that xray -test can load them (using the current
# config.d), then atomically replace the live assets. Rolls back on any failure.
#
# Env (from /etc/xray/secret.env or /etc/xray/repo.env):
#   GEOSITE_URL         — full URL to geosite.dat (required)
#   GEOIP_URL           — full URL to geoip.dat (required)
#   GEOSITE_CUSTOM_URL  — full URL to geosite-custom.dat (optional, empty = skipped)
#
# Reference the custom file in Xray routing rules as:
#   "domain": ["ext:geosite-custom.dat:<tag>"]

set -eu

XRAY_ROOT="/etc/xray"
ASSET_DIR="/usr/local/xray"
XRAY_BIN="/usr/local/xray/xray"
STATE="$XRAY_ROOT/state"
CONF_DIR="$XRAY_ROOT/config.d"

log() { printf '[update-assets] %s\n' "$*"; }
die() { printf '[update-assets][FATAL] %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1091
[ -r "$XRAY_ROOT/secret.env" ] && . "$XRAY_ROOT/secret.env"
# shellcheck disable=SC1091
[ -r "$XRAY_ROOT/repo.env"   ] && . "$XRAY_ROOT/repo.env"

: "${GEOSITE_URL:?GEOSITE_URL not set}"
: "${GEOIP_URL:?GEOIP_URL not set}"

if command -v curl >/dev/null 2>&1; then DL='curl -fsSL -o'
elif command -v wget >/dev/null 2>&1; then DL='wget -q -O'
else die 'neither curl nor wget present'
fi

tmp=$(mktemp -d "$STATE/assets.XXXXXX") || die 'mktemp failed'
trap 'rm -rf "$tmp"' EXIT INT TERM

log 'downloading geosite.dat'
$DL "$tmp/geosite.dat" "$GEOSITE_URL" || die 'geosite download failed'
[ -s "$tmp/geosite.dat" ] || die 'geosite.dat empty'

log 'downloading geoip.dat'
$DL "$tmp/geoip.dat" "$GEOIP_URL" || die 'geoip download failed'
[ -s "$tmp/geoip.dat" ] || die 'geoip.dat empty'

# Optional custom geosite. If URL is set, fetch new. If not set, keep whatever
# is currently installed (so xray -test can still resolve ext:geosite-custom.dat
# references that may exist in the config).
custom_new=0
if [ -n "${GEOSITE_CUSTOM_URL:-}" ]; then
    log 'downloading geosite-custom.dat'
    $DL "$tmp/geosite-custom.dat" "$GEOSITE_CUSTOM_URL" || die 'geosite-custom download failed'
    [ -s "$tmp/geosite-custom.dat" ] || die 'geosite-custom.dat empty'
    custom_new=1
elif [ -e "$ASSET_DIR/geosite-custom.dat" ]; then
    cp -p "$ASSET_DIR/geosite-custom.dat" "$tmp/geosite-custom.dat"
fi

# Validate: point xray at tmp as asset dir and run -test.
# On a fresh bootstrap config.d may still be empty; xray -test has
# nothing to load and would either error or hang. Skip gracefully —
# update-managed-stack.sh runs its own xray -test after rendering.
log 'validating with xray -test'
if ls "$CONF_DIR"/*.json >/dev/null 2>&1; then
    XRAY_LOCATION_ASSET="$tmp" "$XRAY_BIN" -test -confdir "$CONF_DIR" \
        > "$tmp/test.log" 2>&1 \
        || { cat "$tmp/test.log" >&2; die 'xray -test failed with new assets'; }
else
    log 'config.d is empty (first-run); skipping xray -test'
fi

# Atomic replace: backup current, install new
ts=$(date +%Y%m%d-%H%M%S)
mkdir -p "$STATE/assets-backup"

backup_one() {
    f="$1"
    if [ -e "$ASSET_DIR/$f" ]; then
        cp -p "$ASSET_DIR/$f" "$STATE/assets-backup/${f}.${ts}"
    fi
}

backup_one geosite.dat
backup_one geoip.dat
[ "$custom_new" = "1" ] && backup_one geosite-custom.dat

# keep only 3 most recent backups of each
for base in geosite.dat geoip.dat geosite-custom.dat; do
    # shellcheck disable=SC2010
    ls -1t "$STATE/assets-backup/" 2>/dev/null | grep "^${base}\." | awk 'NR>3' \
        | while read -r old; do rm -f "$STATE/assets-backup/$old"; done
done

mv "$tmp/geosite.dat" "$ASSET_DIR/geosite.dat"
mv "$tmp/geoip.dat"   "$ASSET_DIR/geoip.dat"
if [ "$custom_new" = "1" ]; then
    mv "$tmp/geosite-custom.dat" "$ASSET_DIR/geosite-custom.dat"
fi

# Ask procd to re-exec xray (gentle reload; procd handles it)
/etc/init.d/xray reload >/dev/null 2>&1 || true

date +'%Y-%m-%dT%H:%M:%S%z' > "$STATE/last-update-assets.txt"
log 'OK'
