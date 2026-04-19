#!/bin/sh
# apply-iprules.sh
#
# Routing policy for xray's data path. Two independent concerns:
#
#   1. BYPASS MARK (0xff) — Xray sets SO_MARK=0xff on its OWN outbound
#      sockets (the tunnels to the proxy VPS). Those packets must NEVER
#      hit the tproxy path; they go out via the main table directly.
#      Priority 9000, evaluated first.
#
#   2. TPROXY MARK (0x1) — nft/prerouting sets fwmark=0x1 on LAN packets
#      destined for xray's transparent listener (c-def-in:10813). The
#      kernel routes them to the `local` table via fwmark rule, which is
#      what lets a non-locally-addressed packet be accepted by a local
#      socket. This is the core of how TPROXY works on Linux.
#      Priority 9001, evaluated after bypass.
#
# Usage:
#   apply-iprules.sh apply    # add rules + local route
#   apply-iprules.sh flush    # remove everything we set up
#
# Idempotent (safe to run many times).

set -eu

action="${1:-apply}"

BYPASS_MARK="0xff"
BYPASS_PRIO="9000"

TPROXY_MARK="0x1"
TPROXY_TABLE="100"
TPROXY_PRIO="9001"

# ------- helpers ----------------------------------------------------------

flush_rules() {
    # ip rule del removes one match at a time — loop until gone.
    while ip -4 rule show | grep -q "fwmark $BYPASS_MARK"; do
        ip -4 rule del fwmark "$BYPASS_MARK" 2>/dev/null || break
    done
    while ip -4 rule show | grep -q "fwmark $TPROXY_MARK"; do
        ip -4 rule del fwmark "$TPROXY_MARK" 2>/dev/null || break
    done
    # Drop our local route (if present). `|| true` because it may already
    # be gone or may never have been added.
    ip -4 route flush table "$TPROXY_TABLE" 2>/dev/null || true
}

# ------- main -------------------------------------------------------------

case "$action" in
    apply)
        flush_rules
        # 1. xray-own outbound (mark 0xff) -> main table.
        #    Belt-and-suspenders against our own tproxy rules picking up
        #    the tunnel sockets. Priority 9000 so it's evaluated first.
        ip -4 rule add fwmark "$BYPASS_MARK" lookup main priority "$BYPASS_PRIO"

        # 2. tproxy-marked packets -> local table (everything is "local").
        #    This is what makes TPROXY'd packets deliverable to a process
        #    bound on 127.0.0.1 even though dst != 127.0.0.1.
        ip -4 rule add fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" priority "$TPROXY_PRIO"

        # 3. The local table: route EVERY dst to lo as "local" (RTN_LOCAL).
        #    Only reached via the fwmark rule above, so doesn't affect
        #    normal routing.
        ip -4 route add local 0.0.0.0/0 dev lo table "$TPROXY_TABLE"
        ;;
    flush)
        flush_rules
        ;;
    *)
        echo "usage: $0 {apply|flush}" >&2
        exit 2
        ;;
esac
