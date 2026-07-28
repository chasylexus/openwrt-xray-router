#!/bin/sh
# update-all.sh
#
# Manual "bring everything current" wrapper. Runs the managed template/helper
# refresh first, immediately rehydrates live nft sets (apply-nft recreates the
# xray_* tables with empty sets), waits for the router-side T inbound to come
# back after each Xray reload, then asset refresh, remote list refresh,
# allow-domain refresh, and a final update-sets pass so live nft sets end up
# aligned with whatever changed.
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

have_listen_port() {
    port="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v p=":$port" '
            NR > 1 && $4 ~ (p "$") { found=1 }
            END { exit found ? 0 : 1 }
        '
        return $?
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk -v p=":$port" '
            NR > 2 && $4 ~ (p "$") { found=1 }
            END { exit found ? 0 : 1 }
        '
        return $?
    fi

    return 2
}

wait_for_router_t_inbound() {
    port=10801
    timeout="${XRAY_READY_WAIT_SECS:-10}"
    elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        if have_listen_port "$port"; then
            return 0
        fi
        rc=$?
        if [ "$rc" -eq 2 ]; then
            # Minimal systems may lack ss/netstat. Give procd/xray a short grace
            # period so the immediately following GitHub-backed fetches do not
            # race the reload.
            sleep 2
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    die "router-side T inbound :$port did not become ready within ${timeout}s"
}

run_step update-managed-stack "$XRAY_ROOT/bin/update-managed-stack.sh"
# update-managed-stack re-applies the nft tables from template, which means the
# live sets start empty again until update-sets repopulates them. Prime them
# before any subsequent network fetches that may rely on router-side T routing.
run_step prime-sets          "$XRAY_ROOT/bin/update-sets.sh"
run_step wait-for-router-t-post-managed  wait_for_router_t_inbound
run_step update-assets        "$XRAY_ROOT/bin/update-assets.sh"
run_step wait-for-router-t-post-assets   wait_for_router_t_inbound
run_step fetch-remote-lists   "$XRAY_ROOT/bin/fetch-remote-lists.sh"
run_step fetch-allow-domains  "$XRAY_ROOT/bin/fetch-allow-domains.sh"
run_step update-sets          "$XRAY_ROOT/bin/update-sets.sh"

log 'OK'
