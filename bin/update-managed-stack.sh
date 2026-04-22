#!/bin/sh
# update-managed-stack.sh
#
# Download fresh templates (xray/*, nft/*, dnsmasq/*) from REPO_RAW into
# a staged area, render them, validate (xray -test, nft -c), snapshot the
# current working set, then atomically install.
#
# Also renders the dnsmasq optional snippet — if that fails alone, we still
# proceed with xray+nft because dnsmasq is explicitly NOT critical path.

set -eu

XRAY_ROOT="/etc/xray"
TPL_DIR="$XRAY_ROOT/templates"
CONF_D="$XRAY_ROOT/config.d"
NFT_D="$XRAY_ROOT/nft.d"
DNS_D="$XRAY_ROOT/dnsmasq.d"
STATE="$XRAY_ROOT/state"
XRAY_BIN="/usr/local/xray/xray"
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

log()  { printf '[managed] %s\n' "$*"; }
warn() { printf '[managed][WARN] %s\n' "$*" >&2; }
die()  { printf '[managed][FATAL] %s\n' "$*" >&2; exit 1; }

if [ -r "$SELF_DIR/load-env.sh" ]; then
    # shellcheck disable=SC1091
    . "$SELF_DIR/load-env.sh"
    xray_load_env
else
    # Compatibility fallback for older routers that updated helper scripts
    # before load-env.sh existed in /etc/xray/bin.
    [ -r "$XRAY_ROOT/repo.env" ] && . "$XRAY_ROOT/repo.env"
    [ -r "$XRAY_ROOT/secret.env" ] && . "$XRAY_ROOT/secret.env"
    : "${T_PORT:=443}"
    : "${A_PORT:=443}"
fi

: "${REPO_RAW:?REPO_RAW not set (pinned in /etc/xray/repo.env)}"

if command -v curl >/dev/null 2>&1; then DL='curl -fsSL -o'
elif command -v wget >/dev/null 2>&1; then DL='wget -q -O'
elif command -v uclient-fetch >/dev/null 2>&1; then DL='uclient-fetch -O'
else die 'no downloader present (curl, wget, uclient-fetch)'
fi

mkdir -p "$STATE" "$TPL_DIR/xray" "$TPL_DIR/nft" "$TPL_DIR/dnsmasq"
stage=$(mktemp -d "$STATE/managed.XXXXXX") || die 'mktemp failed'
mkdir -p \
    "$stage/xray" "$stage/nft" "$stage/dnsmasq" \
    "$stage/bin" "$stage/lists" \
    "$stage/config.d" "$stage/nft.d" "$stage/dnsmasq.d"
trap 'rm -rf "$stage"' EXIT INT TERM

# ------- 1. download templates -------------------------------------------

dl_tpl() {
    sub="$1"; fname="$2"
    url="$REPO_RAW/$sub/$fname"
    $DL "$stage/$sub/$fname" "$url" || die "download failed: $url"
    [ -s "$stage/$sub/$fname" ]    || die "empty template: $fname"
}

dl_bin() {
    fname="$1"
    url="$REPO_RAW/bin/$fname"
    $DL "$stage/bin/$fname" "$url" || die "download failed: $url"
    [ -s "$stage/bin/$fname" ]     || die "empty helper: $fname"
    head -1 "$stage/bin/$fname" | grep -q '^#!' || die "not a shell script: $fname"
    chmod 755 "$stage/bin/$fname"
}

dl_list_seed() {
    fname="$1"
    url="$REPO_RAW/lists/$fname"
    $DL "$stage/lists/$fname" "$url" || die "download failed: $url"
    [ -s "$stage/lists/$fname" ]     || die "empty list seed: $fname"
}

log 'downloading xray templates'
for f in 00-base.json.tpl 10-inbounds.json.tpl 20-outbounds.json.tpl 50-routing.json.tpl; do
    dl_tpl xray "$f"
done

log 'downloading nft templates'
for f in 10-router-output.nft.tpl 20-clients-prerouting.nft.tpl; do
    dl_tpl nft "$f"
done

log 'downloading dnsmasq template'
if ! $DL "$stage/dnsmasq/90-nftset.conf.tpl" "$REPO_RAW/dnsmasq/90-nftset.conf.tpl"; then
    warn 'dnsmasq template download failed; continuing (bonus layer)'
    : > "$stage/dnsmasq/90-nftset.conf.tpl"
fi

log 'downloading managed helper scripts'
for f in render-template.sh load-env.sh ensure-crontab.sh apply-iprules.sh apply-nft.sh run-xray.sh merge-lists.sh update-sets.sh update-managed-stack.sh update-all.sh update-assets.sh fetch-remote-lists.sh fetch-allow-domains.sh cap-volatile-logs.sh; do
    dl_bin "$f"
done

log 'downloading starter lists'
for f in c-T-dst-v4.txt c-A-dst-v4.txt; do
    dl_list_seed "$f"
done

# ------- 2. render -------------------------------------------------------

render_dir() {
    src_sub="$1"; dst_sub="$2"; ext_old="$3"; ext_new="$4"
    for f in "$stage/$src_sub"/*."$ext_old"; do
        [ -e "$f" ] || continue
        base=$(basename "$f" ".$ext_old")
        out="$stage/$dst_sub/${base}.${ext_new}"
        "$RENDER" "$f" >"$out" || die "render failed: $f"
    done
}

log 'rendering'
RENDER="$stage/bin/render-template.sh"
render_dir xray    config.d  json.tpl  json
render_dir nft     nft.d     nft.tpl   nft
# dnsmasq: only if template is non-empty
if [ -s "$stage/dnsmasq/90-nftset.conf.tpl" ]; then
    "$RENDER" "$stage/dnsmasq/90-nftset.conf.tpl" >"$stage/dnsmasq.d/90-nftset.conf" \
        || warn 'dnsmasq render failed; continuing'
fi

# ------- 3. validate xray ------------------------------------------------

log 'xray -test against staged config'
"$XRAY_BIN" -test -confdir "$stage/config.d" >"$stage/xray-test.log" 2>&1 \
    || { cat "$stage/xray-test.log" >&2; die 'xray -test rejected new config'; }

# ------- 4. validate nft (syntax + live-state compatibility) -----------
#
# Individual `nft -c -f <file>` is NOT enough: if a live chain has a
# different declaration than the staged one (e.g. type nat -> type
# filter during REDIRECT -> TPROXY migration), nft rejects the file as
# redefining a chain with different properties. We must show nft the
# delete-then-add transaction as a whole, matching what apply-nft.sh
# actually does at apply time.
{
    nft list table inet xray_router  >/dev/null 2>&1 && echo 'delete table inet xray_router;'
    nft list table inet xray_clients >/dev/null 2>&1 && echo 'delete table inet xray_clients;'
    cat "$stage/nft.d"/*.nft
} | nft -c -f - || die 'nft -c rejected staged ruleset (chain type conflict with live state?)'

# ------- 5. snapshot current ---------------------------------------------

snap="$STATE/last-good-managed.tar.gz"
if [ -d "$CONF_D" ] || [ -d "$NFT_D" ] || [ -d "$DNS_D" ]; then
    # tar cz may not have --ignore-failed-read on busybox; we pre-check
    ( cd / && tar czf "$snap.new.$$" \
        "etc/xray/config.d" \
        "etc/xray/nft.d" \
        "etc/xray/dnsmasq.d" 2>/dev/null ) || true
    [ -s "$snap.new.$$" ] && mv "$snap.new.$$" "$snap"
fi

# ------- 6. install ------------------------------------------------------

# xray: replace all *.json in config.d with rendered set.
# Policy: we replace ONLY the four canonical file names. Any user-authored
# extras in config.d (e.g. 99-local.json) are preserved.
for base in 00-base 10-inbounds 20-outbounds 50-routing; do
    cp -p "$stage/config.d/${base}.json" "$CONF_D/${base}.json.new.$$"
    mv "$CONF_D/${base}.json.new.$$"     "$CONF_D/${base}.json"
done
rm -f "$TPL_DIR"/xray/*.tpl
cp -p "$stage/xray/"*.tpl "$TPL_DIR/xray/"

for base in 10-router-output 20-clients-prerouting; do
    cp -p "$stage/nft.d/${base}.nft" "$NFT_D/${base}.nft.new.$$"
    mv "$NFT_D/${base}.nft.new.$$"   "$NFT_D/${base}.nft"
done
rm -f "$TPL_DIR"/nft/*.tpl
cp -p "$stage/nft/"*.tpl "$TPL_DIR/nft/"

if [ -s "$stage/dnsmasq.d/90-nftset.conf" ]; then
    cp -p "$stage/dnsmasq.d/90-nftset.conf" "$DNS_D/90-nftset.conf.new.$$"
    mv    "$DNS_D/90-nftset.conf.new.$$"    "$DNS_D/90-nftset.conf"
    rm -f "$TPL_DIR/dnsmasq/"*.tpl
    cp -p "$stage/dnsmasq/"*.tpl "$TPL_DIR/dnsmasq/" 2>/dev/null || true
    # symlink into confdir used by dnsmasq (/etc/dnsmasq.d)
    mkdir -p /etc/dnsmasq.d
    ln -sf "$DNS_D/90-nftset.conf" /etc/dnsmasq.d/90-nftset.conf
else
    # if absent, make sure we do not leave a stale symlink
    [ -L /etc/dnsmasq.d/90-nftset.conf ] && rm -f /etc/dnsmasq.d/90-nftset.conf
    [ -e "$DNS_D/90-nftset.conf" ] && rm -f "$DNS_D/90-nftset.conf"
fi

for f in render-template.sh load-env.sh ensure-crontab.sh apply-iprules.sh apply-nft.sh run-xray.sh merge-lists.sh update-sets.sh update-managed-stack.sh update-all.sh update-assets.sh fetch-remote-lists.sh fetch-allow-domains.sh cap-volatile-logs.sh; do
    cp -p "$stage/bin/$f" "$XRAY_ROOT/bin/$f.new.$$"
    chmod 755 "$XRAY_ROOT/bin/$f.new.$$"
    mv "$XRAY_ROOT/bin/$f.new.$$" "$XRAY_ROOT/bin/$f"
done

for f in c-T-dst-v4.txt c-A-dst-v4.txt; do
    [ -e "$XRAY_ROOT/lists/local/$f" ] && continue
    cp -p "$stage/lists/$f" "$XRAY_ROOT/lists/local/$f"
done

# ------- 7. apply --------------------------------------------------------

log 'reloading xray (procd)'
/etc/init.d/xray reload >/dev/null 2>&1 || warn 'xray reload returned non-zero'

log 'applying nft'
"$XRAY_ROOT/bin/apply-nft.sh" apply || die 'apply-nft failed'

# dnsmasq restart only if snippet present and changed; cheap unconditional restart
if [ -s "$DNS_D/90-nftset.conf" ]; then
    log 'restarting dnsmasq (bonus layer)'
    /etc/init.d/dnsmasq reload >/dev/null 2>&1 || warn 'dnsmasq reload failed (bonus layer)'
fi

date +'%Y-%m-%dT%H:%M:%S%z' > "$STATE/last-update-managed.txt"
log 'OK'
