#!/bin/sh
# render-managed-config.sh
#
# Render the locally installed Xray templates from /etc/xray/templates/xray
# into /etc/xray/config.d using the current secret.env/repo.env values.
# This lets a plain reboot or service restart pick up env toggles such as
# ENABLE_IPV6 without downloading templates again.

set -eu

XRAY_ROOT="/etc/xray"
TPL_DIR="$XRAY_ROOT/templates/xray"
OUT_DIR="$XRAY_ROOT/config.d"
RENDER="$XRAY_ROOT/bin/render-template.sh"
SANITIZE="$XRAY_ROOT/bin/sanitize-routing-rules.sh"

log() { printf '[render-managed] %s\n' "$*"; }
die() { printf '[render-managed][FATAL] %s\n' "$*" >&2; exit 1; }

action="${1:-apply}"

case "$action" in
    apply) : ;;
    *)
        echo "usage: $0 apply" >&2
        exit 2
        ;;
esac

[ -d "$TPL_DIR" ] || die "template dir missing: $TPL_DIR"
[ -x "$RENDER" ] || die "renderer missing: $RENDER"

mkdir -p "$OUT_DIR"

for base in 00-base 10-inbounds 20-outbounds 50-routing; do
    tpl="$TPL_DIR/${base}.json.tpl"
    out="$OUT_DIR/${base}.json"
    staged="$OUT_DIR/${base}.json.staged.$$"

    [ -r "$tpl" ] || die "template missing: $tpl"
    "$RENDER" "$tpl" > "$staged" || die "render failed: $tpl"

    if [ "$base" = "50-routing" ] && [ -x "$SANITIZE" ]; then
        sanitized="$OUT_DIR/${base}.json.sanitized.$$"
        "$SANITIZE" "$staged" "$sanitized" || die "routing sanitization failed"
        mv "$sanitized" "$staged"
    fi

    mv "$staged" "$out"
done

log 'OK'
