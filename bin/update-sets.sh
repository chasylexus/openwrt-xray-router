#!/bin/sh
# update-sets.sh
#
# Merge lists, resolve domain lists to IPv4 via nslookup, and atomically
# replace the element contents of nft sets (no table rebuild).
#
# Sets:
#   Router-side (nat/output, REDIRECT to loopback):
#     r_T_v4          <- r-T-ipv4.txt + resolve(r-T-domains.txt)
#     r_A_v4          <- r-A-ipv4.txt + resolve(r-A-domains.txt)
#
#   Client-side (prerouting, TPROXY) — user-curated bypass. These skip
#   xray entirely (return from prerouting). NOT per-outbound routing
#   (that lives in xray — see commit 7f118eb for CDN-collision rationale):
#     c_bypass_dst_v4 <- c-bypass-dst-v4.txt (static IPs, no resolve)
#     c_bypass_src_v4 <- c-bypass-src-v4.txt (LAN source IPs, no resolve)
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

# Helper: resolve one domain -> IPv4 lines. Written to $WORK/resolve-one.sh
# so we can spawn it in parallel without quoting hell. Each child does
# nslookup + per-invocation awk filter, then writes only clean IPv4 lines
# to stdout — so downstream pipe can mix outputs safely.
write_resolver() {
    cat > "$1" <<'RESOLVE_EOF'
#!/bin/sh
nslookup "$1" 2>/dev/null | awk '
    /^Name:/    { flag=1; next }
    /^Address/ && flag {
        sub(/^Address[0-9]*:[[:space:]]*/, "", $0)
        if ($0 ~ /:/) next
        print $0
    }
'
RESOLVE_EOF
    chmod +x "$1"
}

# Pure-shell parallel resolver — BusyBox on OpenWrt 25.12 is compiled
# WITHOUT FEATURE_XARGS_SUPPORT_PARALLEL, so `xargs -P` is unavailable
# (even `-P 1` errors out). We shard the domain file by `NR % N` into N
# worker subshells with `&` and join with `wait`. POSIX-guaranteed,
# no external dependencies.
#
# Each worker reads only its slice of the file and calls $RESOLVER
# sequentially; the N workers run concurrently, giving the same ~N×
# speedup we used to get from xargs -P.
parallel_resolve() {
    df="$1"
    N="${2:-16}"
    [ -s "$df" ] || return 0
    k=0
    while [ "$k" -lt "$N" ]; do
        (
            awk -v n="$N" -v k="$k" 'NR % n == k' "$df" |
            while IFS= read -r dom; do
                [ -z "$dom" ] && continue
                "$RESOLVER" "$dom"
            done
        ) &
        k=$((k + 1))
    done
    wait
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
            # Parallel DNS resolution — ~10-16x faster on lists with
            # hundreds/thousands of domains. Without this, a cron tick
            # on c-T-domains.txt (~1200 domains) takes 4-5 minutes.
            parallel_resolve "$domain_file" "$PARALLEL"
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

RESOLVER="$WORK/resolve-one.sh"
write_resolver "$RESOLVER"
PARALLEL="${RESOLVE_PARALLEL:-16}"
log "resolving domains with parallelism=$PARALLEL (shell-native)"

# NOTE: per-outbound client-side sets (c_D_v4 / c_T_v4 / c_A_v4) were
# removed in 7f118eb — domain-based routing lives entirely in xray because
# IP-level matching breaks on CDNs. The client-side bypass sets below are
# safe because they only make "skip xray entirely" decisions; no
# domain-to-outbound mapping happens at this layer.
#
# /dev/null as domain_file => IPs only, no resolve step.
stage_set inet\ xray_router   r_T_v4           "$MERGED/r-T-ipv4.txt"         "$MERGED/r-T-domains.txt"   "$WORK/r_T_v4"
stage_set inet\ xray_router   r_A_v4           "$MERGED/r-A-ipv4.txt"         "$MERGED/r-A-domains.txt"   "$WORK/r_A_v4"
stage_set inet\ xray_clients  c_bypass_dst_v4  "$MERGED/c-bypass-dst-v4.txt"  /dev/null                   "$WORK/c_bypass_dst_v4"
stage_set inet\ xray_clients  c_bypass_src_v4  "$MERGED/c-bypass-src-v4.txt"  /dev/null                   "$WORK/c_bypass_src_v4"

# ------- step 3: validate: tables must exist ------------------------------
nft list table inet xray_router  >/dev/null 2>&1 || die 'inet xray_router missing — run: /etc/init.d/xray reload'
nft list table inet xray_clients >/dev/null 2>&1 || die 'inet xray_clients missing — run: /etc/init.d/xray reload'

# ------- step 4: snapshot current ----------------------------------------
#
# Tolerant: a set may not yet exist during an architecture migration (e.g.
# first run after introducing a new set in the template but before
# apply-nft.sh has (re)created the table). Don't abort snapshot in that
# case — just record the gap as a comment.
snap_set() {
    if nft list set inet "$1" "$2" 2>/dev/null; then : ; else
        printf '# snapshot: set inet %s %s was absent at snapshot time\n' "$1" "$2"
    fi
}
{
    snap_set xray_router   r_T_v4
    snap_set xray_router   r_A_v4
    snap_set xray_clients  c_bypass_dst_v4
    snap_set xray_clients  c_bypass_src_v4
} > "$LAST_GOOD.new.$$"
mv "$LAST_GOOD.new.$$" "$LAST_GOOD"

# ------- step 5: dry-run path -------------------------------------------
if [ "$mode" = "--dry-run" ]; then
    for s in r_T_v4 r_A_v4 c_bypass_dst_v4 c_bypass_src_v4; do
        [ -f "$WORK/$s" ] || continue
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
    # Tolerant to partial-migration state: if the target set is not yet
    # in kernel (e.g. apply-nft has not run with the latest template),
    # skip rather than abort the whole transaction. The next
    # apply-nft → update-sets cycle will catch up.
    if ! nft list set inet "$table" "$name" >/dev/null 2>&1; then
        printf '[update-sets] skip: set inet %s %s absent in kernel (run apply-nft first)\n' \
            "$table" "$name" >&2
        return 0
    fi
    # Always flush — even for empty sets — so stale entries are cleared.
    printf 'flush set inet %s %s\n' "$table" "$name"
    [ -s "$src" ] || return 0
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
    build_add xray_router   r_T_v4          "$WORK/r_T_v4"
    build_add xray_router   r_A_v4          "$WORK/r_A_v4"
    build_add xray_clients  c_bypass_dst_v4 "$WORK/c_bypass_dst_v4"
    build_add xray_clients  c_bypass_src_v4 "$WORK/c_bypass_src_v4"
} > "$WORK/apply.nft"

nft -c -f "$WORK/apply.nft" || die 'nft -c rejected the generated script'
nft    -f "$WORK/apply.nft" || die 'nft -f failed during apply (state may be partial; last-good-sets.txt is safe)'

# ------- step 7: done ----------------------------------------------------
for s in r_T_v4 r_A_v4 c_bypass_dst_v4 c_bypass_src_v4; do
    [ -f "$WORK/$s" ] || continue
    n=$(wc -l < "$WORK/$s" | awk '{print $1}')
    log "$s applied ($n elements)"
done
date +'%Y-%m-%dT%H:%M:%S%z' > "$STATE/last-update-sets.txt"
log 'OK'
