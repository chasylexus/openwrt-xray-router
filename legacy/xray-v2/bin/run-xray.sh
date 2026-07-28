#!/bin/sh
# run-xray.sh
#
# Thin wrapper used by /etc/init.d/xray via procd_set_param command.
# Validates config before exec, then exec's Xray.
# Meant to be exec'd, not backgrounded — procd handles supervision.

set -eu

XRAY_BIN="/usr/local/xray/xray"
XRAY_ASSET_DIR="/usr/local/xray"
CONF_DIR="/etc/xray/config.d"

# Pre-exec validation — if the merged config is broken, fail loud and fast so
# procd's respawn counter notices immediately.
"$XRAY_BIN" -test -confdir "$CONF_DIR" >/tmp/xray-test.log 2>&1 || {
    echo "xray -test failed; see /tmp/xray-test.log" >&2
    cat /tmp/xray-test.log >&2
    exit 1
}

# Xray reads XRAY_LOCATION_ASSET for geosite/geoip files.
XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR"
export XRAY_LOCATION_ASSET

exec "$XRAY_BIN" run -confdir "$CONF_DIR"
