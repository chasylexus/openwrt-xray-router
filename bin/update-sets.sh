#!/bin/sh
# update-sets.sh
#
# Merge lists, resolve domain lists to IPv4 via nslookup, and atomically
# replace the element contents of nft sets (no table rebuild).
#
# Sets:
#   r_T_v4 <- r-T-ipv4.txt + resolve(r-T-domains.txt)
#   r_A_v4 <- r-A-ipv4.txt + resolve(r-A-domains.txt)
#   c_D_v4 <- c-D-ipv4.txt + resolve(c-D-domains.txt)
#   c_T_v4 <- c-T-ipv4.txt + resolve(c-T-domains.txt)
#   c_A_v4 <- c-A-ipv4.txt + resolve(c-A-domains.txt)
#
# Safe: snapshots current set contents to /etc/xray/state/last-good-sets.txt
# before replacing. On any resolution error that produces an empty result for
# a non-empty input, the entire run aborts without touching sets.
#
# Usage:
#   update-sets.sh               # normal
#   update-sets.sh --restore     # restore from last-good-sets.txt
#   update-sets.sh --dry-run     # print what would change, do nothing

set -eu

XRAY_ROOT="/etc/xray"
MERGED="$XRAY_ROOT/lists/merged"
STATE="$XRAY_ROOT/state"
LAST_GOOD="$STATE/last-good-sets.txt"
MERGER="$XRAY_ROOT/bin/merge-lists.sh"

log() { printf '[update-sets] %s\n' "$*"; }
die() { printf '[update-sets][FATAL] %s\n' "$*" >&2; exit 1; }

mkdir -p "$STATE"

mode="${1:-normal}"

# ------- restore path ----------------------------------------------------
if [ "$mode" = "--restore" ]; then
    [ -r "$LAST_GOOD" ] || die "no last-good-sets.txt to restore from"
    log "restoring from $LAST_GOOD"
    nft -f "$LAST_GOOD"
    log 'restore OK'
    exit 0
fi

# ------- preflight -------------------------------------------------------
command -v nslookup >/dev/null 2>&1 || die 'nslookup not found'
command -v nft      >/dev/null 2>&1 || die 'nft not found'

# ------- step 1: rebuild merged lists ------------------------------------
"$MERGER" || die 'merge-lists failed'

# ------- step 2: resolve domains to IPv4 --------------------------------
#
# One DNS lookup per line. Use system resolver (dnsmasq on this router).
# If a domain fails to resolve we WARN but continue — the whole run only
# aborts if the resulting set for a non-empty input domain list would be
# empty AND the ipv4 companion list is also empty (i.e. we'd clear a live set).

resolve_domain() {
    # prints one IPv4 per line, possibly empty
    nslookup "$1" 2>/dev/null \
      | awk '
          /^Name:/   { getname=1; next }
          /^Address/ && getname {
              sub(/^Address[0-9]*:[[:space:]]*/,"",$0)
              # ignore IPv6
              if ($0 ~ /:/) next
              print $0
          }
        '
}

# Build a staged file per set, source of truth: merged/*.txt
stage_set() {
    set_table="$1"
    set_name="$2"
    ipv4_file="$3"
    domain_file="$4"
    out="$5"

    {
        [ -s "$ipv4_file" ] && cat "$ipv4_file"
        if [ -s "$domain_file" ]; then
            while IFS= read -r dom; do
                [ -z "$dom" ] && continue
                resolve_domain "$dom"
            done < "$domain_file"
        fi
    } | awk '
        /^[0-9]{1,3}(\.[0-9]{1,3}){3}(\/[0-9]{1,2})?$/ { print }
      ' | sort -u > "$out"

    # sanity: non-empty input must not produce empty output
    in_nonempty=0
    [ -s "$ipv4_file" ]   && in_nonempty=1
    [ -s "$domain_file" ] && in_nonempty=1
    if [ "$in_nonempty" = "1" ] && [ ! -s "$out" ]; then
        die "staged $set_table $set_name is empty but input was non-empty — refusing to clear live set"
    fi
}

WORK="$STATE/update-sets.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT INT TERM

stage_set inet\ xray_router  r_T_v4 "$MERGED/r-T-ipv4.txt"  "$MERGED/r-T-domains.txt"  "$WORK/r_T_v4"
stage_set inet\ xray_router  r_A_v4 "$MERGED/r-A-ipv4.txt"  "$MERGED/r-A-domains.txt"  "$WORK/r_A_v4"
stage_set inet\ xray_clients c_D_v4 "$MERGED/c-D-ipv4.txt"  "$MERGED/c-D-domains.txt"  "$WORK/c_D_v4"
stage_set inet\ xray_clients c_T_v4 "$MERGED/c-T-ipv4.txt"  "$MERGED/c-T-domains.txt"  "$WORK/c_T_v4"
stage_set inet\ xray_clients c_A_v4 "$MERGED/c-A-ipv4.txt"  "$MERGED/c-A-domains.txt"  "$WORK/c_A_v4"

# ------- step 3: validate: tables must exist ------------------------------
nft list table inet xray_router  >/dev/null 2>&1 || die 'inet xray_router missing — run: /etc/init.d/xray reload'
nft list table inet xray_clients >/dev/null 2>&1 || die 'inet xray_clients missing — run: /etc/init.d/xray reload'

# ------- step 4: snapshot current ----------------------------------------
{
    nft list set inet xray_router  r_T_v4
    nft list set inet xray_router  r_A_v4
    nft list set inet xray_clients c_D_v4
    nft list set inet xray_clients c_T_v4
    nft list set inet xray_clients c_A_v4
} > "$LAST_GOOD.new.$$"
mv "$LAST_GOOD.new.$$" "$LAST_GOOD"

# ------- step 5: dry-run path -------------------------------------------
if [ "$mode" = "--dry-run" ]; then
    for s in r_T_v4 r_A_v4 c_D_v4 c_T_v4 c_A_v4; do
        n=$(wc -l < "$WORK/$s")
        log "$s would have $n elements"
    done
    exit 0
fi

# ------- step 6: apply atomically ----------------------------------------
#
# Build one nft script that:
#   flush set <table> <name>
#   add element <table> <name> { ip1, ip2, ... }
# ...for each set. Then nft -f in one shot.

build_add() {
    table="$1"
    name="$2"
    src="$3"
    [ -s "$src" ] || return 0
    printf 'flush set inet %s %s\n' "$table" "$name"
    printf 'add element inet %s %s { ' "$table" "$name"
    # comma-separated, multiline tolerated
    first=1
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        if [ "$first" = 1 ]; then
            printf '%s' "$ip"
            first=0
        else
            printf ', %s' "$ip"
        fi
    done < "$src"
    printf ' }\n'
}

{
    build_add xray_router  r_T_v4 "$WORK/r_T_v4"
    build_add xray_router  r_A_v4 "$WORK/r_A_v4"
    build_add xray_clients c_D_v4 "$WORK/c_D_v4"
    build_add xray_clients c_T_v4 "$WORK/c_T_v4"
    build_add xray_clients c_A_v4 "$WORK/c_A_v4"
} > "$WORK/apply.nft"

nft -c -f "$WORK/apply.nft" || die 'nft -c rejected the generated script'
nft    -f "$WORK/apply.nft" || die 'nft -f failed during apply (state may be partial; last-good-sets.txt is safe)'

# ------- step 7: done ----------------------------------------------------
for s in r_T_v4 r_A_v4 c_D_v4 c_T_v4 c_A_v4; do
    n=$(wc -l < "$WORK/$s" | awk '{print $1}')
    log "$s applied ($n elements)"
done
date +'%Y-%m-%dT%H:%M:%S%z' > "$STATE/last-update-sets.txt"
log 'OK'
