#!/bin/sh
# apply-nft.sh
#
# Render nft templates from /etc/xray/templates/nft into /etc/xray/nft.d,
# validate, and apply atomically. Destroys the running xray_* tables and
# replaces them with the freshly rendered ones.
#
# Does NOT touch firewall tables managed by fw4 / OpenWrt default rules —
# we use dedicated table names `xray_router` and `xray_clients`.
#
# Usage:
#   apply-nft.sh apply     # render + validate + apply
#   apply-nft.sh flush     # remove our tables
#
# Env: sourced from /etc/xray/secret.env

set -eu

XRAY_ROOT="/etc/xray"
TPL_DIR="$XRAY_ROOT/templates/nft"
OUT_DIR="$XRAY_ROOT/nft.d"
RENDER="$XRAY_ROOT/bin/render-template.sh"

log()  { printf '[apply-nft] %s\n' "$*"; }
die()  { printf '[apply-nft][FATAL] %s\n' "$*" >&2; exit 1; }

mkdir -p "$OUT_DIR"

action="${1:-apply}"

flush_tables() {
    nft list table inet xray_router  >/dev/null 2>&1 && nft delete table inet xray_router  || true
    nft list table inet xray_clients >/dev/null 2>&1 && nft delete table inet xray_clients || true
}

case "$action" in
    flush)
        flush_tables
        exit 0
        ;;
    apply) : ;;
    *) echo "usage: $0 {apply|flush}" >&2; exit 2 ;;
esac

# Make sure templates exist
for f in 10-router-output.nft.tpl 20-clients-prerouting.nft.tpl; do
    [ -r "$TPL_DIR/$f" ] || die "template missing: $TPL_DIR/$f (run update-managed-stack.sh first)"
done

# Render to staged files
staged_router="$OUT_DIR/10-router-output.nft.staged.$$"
staged_clients="$OUT_DIR/20-clients-prerouting.nft.staged.$$"

trap 'rm -f "$staged_router" "$staged_clients"' EXIT INT TERM

"$RENDER" "$TPL_DIR/10-router-output.nft.tpl"    > "$staged_router"  || die 'render failed: router'
"$RENDER" "$TPL_DIR/20-clients-prerouting.nft.tpl" > "$staged_clients" || die 'render failed: clients'

# Build the full transaction: optional `delete table` preamble (if a
# previous ruleset is in kernel) followed by the staged ruleset. We emit
# this function twice — once with `nft -c` for validation, once with
# `nft` for apply — so both see the SAME transaction.
#
# Why the preamble matters: `nft -c -f <file>` validates against live
# state. If the staged file redeclares a chain with a different `type`
# (e.g. nat hook prerouting -> filter hook prerouting when migrating
# REDIRECT -> TPROXY), nft rejects it as a conflicting redefinition.
# Prepending `delete table` shows nft the full delete-then-add plan and
# the validation passes.
build_transaction() {
    nft list table inet xray_router  >/dev/null 2>&1 && echo 'delete table inet xray_router;'
    nft list table inet xray_clients >/dev/null 2>&1 && echo 'delete table inet xray_clients;'
    cat "$staged_router"
    cat "$staged_clients"
}

# Validate (nft -c runs the full transaction in dry-run; no state change).
build_transaction | nft -c -f - || die 'nft -c rejected staged ruleset'

# Apply atomically: same transaction, without -c.
build_transaction | nft    -f - || die 'nft -f failed during atomic swap'

mv "$staged_router"  "$OUT_DIR/10-router-output.nft"
mv "$staged_clients" "$OUT_DIR/20-clients-prerouting.nft"

log 'OK'
