#!/bin/sh
# apply-iprules.sh
#
# In the redirect/DNAT-based design used here, we do NOT need custom ip rules
# for the data path — everything is handled by `redirect to :port` in nft.
#
# This script still exists because the repo's design is forward-compatible
# with a future TPROXY-based UDP path, which would need:
#   ip rule add fwmark 0x1/0xff lookup 100
#   ip route add local default dev lo table 100
#
# For now it manages a single housekeeping entry: make sure fwmark 0xff
# (Xray's own outbound marker) is never accidentally routed via any
# non-default table.
#
# Usage:
#   apply-iprules.sh apply    # add
#   apply-iprules.sh flush    # remove
#
# Idempotent.

set -eu

action="${1:-apply}"

BYPASS_MARK="0xff"

# Remove any pre-existing rule matching our mark, regardless of priority.
flush_rules() {
    # Loop because ip rule del removes one at a time.
    while ip -4 rule show | grep -q "fwmark $BYPASS_MARK"; do
        ip -4 rule del fwmark "$BYPASS_MARK" || break
    done
}

case "$action" in
    apply)
        flush_rules
        # explicit bypass to main table — belt-and-suspenders; redirect/DNAT
        # based design does not require this, but it's cheap and future-proof.
        ip -4 rule add fwmark "$BYPASS_MARK" lookup main priority 9000
        ;;
    flush)
        flush_rules
        ;;
    *)
        echo "usage: $0 {apply|flush}" >&2
        exit 2
        ;;
esac
