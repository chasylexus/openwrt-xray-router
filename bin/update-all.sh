#!/bin/sh
# update-all.sh
#
# Manual "bring everything current" wrapper. Runs asset refresh first, then the
# managed template/helper refresh, remote list refresh, allow-domain refresh,
# then a final update-sets pass so live nft sets end up aligned with whatever
# changed.
#
# Intended for manual invocation when you want the router fully updated now,
# instead of waiting for the different cron cadences to converge.

set -eu

XRAY_ROOT="/etc/xray"
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

log()  { printf '[update-all] %s\n' "$*"; }
die()  { printf '[update-all][FATAL] %s\n' "$*" >&2; exit 1; }

# Preload/derive env once in the wrapper so an older installed child script can
# still render newer templates during the self-update hop.
if [ -r "$SELF_DIR/load-env.sh" ]; then
    # shellcheck disable=SC1091
    . "$SELF_DIR/load-env.sh"
    xray_load_env
fi

: "${T_PORT:=443}"
: "${A_PORT:=443}"
export T_PORT A_PORT

run_step() {
    name="$1"
    shift
    log "running $name"
    "$@" || die "$name failed"
}

run_step update-assets        "$XRAY_ROOT/bin/update-assets.sh"
run_step update-managed-stack "$XRAY_ROOT/bin/update-managed-stack.sh"
run_step fetch-remote-lists   "$XRAY_ROOT/bin/fetch-remote-lists.sh"
run_step fetch-allow-domains  "$XRAY_ROOT/bin/fetch-allow-domains.sh"
run_step update-sets          "$XRAY_ROOT/bin/update-sets.sh"

log 'OK'
