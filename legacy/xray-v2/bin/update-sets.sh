#!/bin/sh
# update-sets.sh
#
# Merge lists, resolve domain lists via nslookup, and atomically replace the
# element contents of nft sets (no table rebuild).
#
# Sets:
#   Router-side (nat/output, REDIRECT to loopback):
#     r_T_v4 / r_T_v6 <- r-T-ipv4.txt / r-T-ipv6.txt + resolve(r-T-domains.txt)
#     r_A_v4 / r_A_v6 <- r-A-ipv4.txt / r-A-ipv6.txt + resolve(r-A-domains.txt)
#
#   Client-side (prerouting, TPROXY) — user-curated bypass and per-IP binds:
#     c_bypass_dst_v4 / c_bypass_dst_v6 <- c-bypass-dst-v4.txt / c-bypass-dst-v6.txt
#     c_bypass_src_v4 / c_bypass_src_v6 <- c-bypass-src-v4.txt / c-bypass-src-v6.txt
#     c_T_dst_v4 / c_T_dst_v6           <- c-T-dst-v4.txt / c-T-dst-v6.txt
#     c_A_dst_v4 / c_A_dst_v6           <- c-A-dst-v4.txt / c-A-dst-v6.txt
#
# Safe: snapshots current set contents to /etc/xray/state/last-good-sets.txt
# before replacing. On nft apply failure it restores the last-good snapshot.

set -eu

XRAY_ROOT="/etc/xray"
MERGED="$XRAY_ROOT/lists/merged"
STATE="$XRAY_ROOT/state"
LAST_GOOD="$STATE/last-good-sets.txt"
MERGER="$XRAY_ROOT/bin/merge-lists.sh"
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

log() { printf '[update-sets] %s\n' "$*"; }
warn() { printf '[update-sets][WARN] %s\n' "$*" >&2; }
die() { printf '[update-sets][FATAL] %s\n' "$*" >&2; exit 1; }

mkdir -p "$STATE"

mode="${1:-normal}"

restore_last_good() {
    [ -r "$LAST_GOOD" ] || die "no last-good-sets.txt to restore from"
    nft -f "$LAST_GOOD"
}

if [ "$mode" = "--restore" ]; then
    log "restoring from $LAST_GOOD"
    restore_last_good
    log 'restore OK'
    exit 0
fi

command -v nslookup >/dev/null 2>&1 || die 'nslookup not found'
command -v nft      >/dev/null 2>&1 || die 'nft not found'

if [ -r "$SELF_DIR/load-env.sh" ]; then
    # shellcheck disable=SC1091
    . "$SELF_DIR/load-env.sh"
    xray_load_env
fi

"$MERGER" || die 'merge-lists failed'

write_resolver_v4() {
    cat > "$1" <<'RESOLVE4_EOF'
#!/bin/sh
nslookup "$1" 2>/dev/null | awk '
    /^Name:/    { flag=1; next }
    /^Address/ && flag {
        sub(/^Address[0-9]*:[[:space:]]*/, "", $0)
        if ($0 ~ /:/) next
        print $0
    }
'
RESOLVE4_EOF
    chmod +x "$1"
}

write_resolver_v6() {
    cat > "$1" <<'RESOLVE6_EOF'
#!/bin/sh
nslookup "$1" 2>/dev/null | awk '
    /^Name:/    { flag=1; next }
    /^Address/ && flag {
        sub(/^Address[0-9]*:[[:space:]]*/, "", $0)
        if ($0 ~ /:/) print
    }
'
RESOLVE6_EOF
    chmod +x "$1"
}

parallel_resolve() {
    df="$1"
    N="${2:-16}"
    resolver="$3"
    [ -s "$df" ] || return 0
    k=0
    while [ "$k" -lt "$N" ]; do
        (
            awk -v n="$N" -v k="$k" 'NR % n == k' "$df" |
            while IFS= read -r dom; do
                [ -z "$dom" ] && continue
                "$resolver" "$dom"
            done
        ) &
        k=$((k + 1))
    done
    wait
}

narrow_filter_v4() {
    label="$1"
    in="$2"
    out="$3"
    threshold="$4"
    awk -v t="$threshold" -v label="$label" '
        /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print; next }
        /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {
            n = $0; sub(/.*\//, "", n)
            if (n + 0 >= t + 0) { print; next }
            printf "[update-sets][reject %s] CIDR %s broader than /%s\n", label, $0, t > "/dev/stderr"
        }
    ' "$in" > "$out"
}

narrow_filter_v6() {
    label="$1"
    in="$2"
    out="$3"
    threshold="$4"
    awk -v t="$threshold" -v label="$label" '
        /^[0-9A-Fa-f:]+$/ { print; next }
        /^[0-9A-Fa-f:]+\/[0-9]+$/ {
            n = $0; sub(/.*\//, "", n)
            if (n + 0 >= t + 0) { print; next }
            printf "[update-sets][reject %s] CIDR %s broader than /%s\n", label, $0, t > "/dev/stderr"
        }
    ' "$in" > "$out"
}

stage_set_v4() {
    set_table="$1"
    set_name="$2"
    ipv4_file="$3"
    domain_file="$4"
    out="$5"

    {
        [ -s "$ipv4_file" ] && cat "$ipv4_file"
        [ -s "$domain_file" ] && parallel_resolve "$domain_file" "$PARALLEL" "$RESOLVER_V4"
    } | awk '
        /^[0-9]{1,3}(\.[0-9]{1,3}){3}(\/[0-9]{1,2})?$/ { print }
    ' | sort -u > "$out"

    in_nonempty=0
    [ -s "$ipv4_file" ]   && in_nonempty=1
    [ -s "$domain_file" ] && in_nonempty=1
    if [ "$in_nonempty" = "1" ] && [ ! -s "$out" ]; then
        die "staged $set_table $set_name is empty but input was non-empty — refusing to clear live set"
    fi
}

stage_set_v6() {
    ipv6_file="$1"
    domain_file="$2"
    out="$3"

    {
        [ -s "$ipv6_file" ] && cat "$ipv6_file"
        [ -s "$domain_file" ] && parallel_resolve "$domain_file" "$PARALLEL" "$RESOLVER_V6"
    } | awk '
        /^[0-9A-Fa-f:]+(\/[0-9]{1,3})?$/ { print }
    ' | sort -u > "$out"
}

WORK="$STATE/update-sets.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT INT TERM

RESOLVER_V4="$WORK/resolve-one-v4.sh"
RESOLVER_V6="$WORK/resolve-one-v6.sh"
write_resolver_v4 "$RESOLVER_V4"
write_resolver_v6 "$RESOLVER_V6"
PARALLEL="${RESOLVE_PARALLEL:-16}"
log "resolving domains with parallelism=$PARALLEL (shell-native)"

stage_set_v4 inet\ xray_router   r_T_v4           "$MERGED/r-T-ipv4.txt"         "$MERGED/r-T-domains.txt"   "$WORK/r_T_v4.raw"
narrow_filter_v4 r_T_v4 "$WORK/r_T_v4.raw" "$WORK/r_T_v4" "${ROUTER_DST_MIN_PREFIX:-20}"
stage_set_v4 inet\ xray_router   r_A_v4           "$MERGED/r-A-ipv4.txt"         "$MERGED/r-A-domains.txt"   "$WORK/r_A_v4.raw"
narrow_filter_v4 r_A_v4 "$WORK/r_A_v4.raw" "$WORK/r_A_v4" "${ROUTER_DST_MIN_PREFIX:-20}"
stage_set_v6 "$MERGED/r-T-ipv6.txt" "$MERGED/r-T-domains.txt" "$WORK/r_T_v6.raw"
narrow_filter_v6 r_T_v6 "$WORK/r_T_v6.raw" "$WORK/r_T_v6" "${ROUTER_DST_MIN_PREFIX6:-32}"
stage_set_v6 "$MERGED/r-A-ipv6.txt" "$MERGED/r-A-domains.txt" "$WORK/r_A_v6.raw"
narrow_filter_v6 r_A_v6 "$WORK/r_A_v6.raw" "$WORK/r_A_v6" "${ROUTER_DST_MIN_PREFIX6:-32}"

stage_set_v4 inet\ xray_clients  c_bypass_dst_v4  "$MERGED/c-bypass-dst-v4.txt"  /dev/null "$WORK/c_bypass_dst_v4"
stage_set_v4 inet\ xray_clients  c_bypass_src_v4  "$MERGED/c-bypass-src-v4.txt"  /dev/null "$WORK/c_bypass_src_v4"
stage_set_v6 "$MERGED/c-bypass-dst-v6.txt" /dev/null "$WORK/c_bypass_dst_v6"
stage_set_v6 "$MERGED/c-bypass-src-v6.txt" /dev/null "$WORK/c_bypass_src_v6"

stage_set_v4 inet\ xray_clients  c_T_dst_v4       "$MERGED/c-T-dst-v4.txt"       /dev/null "$WORK/c_T_dst_v4.raw"
narrow_filter_v4 c_T_dst_v4 "$WORK/c_T_dst_v4.raw" "$WORK/c_T_dst_v4" "${CLIENT_DST_MIN_PREFIX:-24}"
stage_set_v4 inet\ xray_clients  c_A_dst_v4       "$MERGED/c-A-dst-v4.txt"       /dev/null "$WORK/c_A_dst_v4.raw"
narrow_filter_v4 c_A_dst_v4 "$WORK/c_A_dst_v4.raw" "$WORK/c_A_dst_v4" "${CLIENT_DST_MIN_PREFIX:-24}"
stage_set_v6 "$MERGED/c-T-dst-v6.txt" /dev/null "$WORK/c_T_dst_v6.raw"
narrow_filter_v6 c_T_dst_v6 "$WORK/c_T_dst_v6.raw" "$WORK/c_T_dst_v6" "${CLIENT_DST_MIN_PREFIX6:-64}"
stage_set_v6 "$MERGED/c-A-dst-v6.txt" /dev/null "$WORK/c_A_dst_v6.raw"
narrow_filter_v6 c_A_dst_v6 "$WORK/c_A_dst_v6.raw" "$WORK/c_A_dst_v6" "${CLIENT_DST_MIN_PREFIX6:-64}"

nft list table inet xray_router  >/dev/null 2>&1 || die 'inet xray_router missing — run: /etc/init.d/xray reload'
nft list table inet xray_clients >/dev/null 2>&1 || die 'inet xray_clients missing — run: /etc/init.d/xray reload'

snap_set() {
    if nft list set inet "$1" "$2" 2>/dev/null; then : ; else
        printf '# snapshot: set inet %s %s was absent at snapshot time\n' "$1" "$2"
    fi
}
{
    snap_set xray_router   r_T_v4
    snap_set xray_router   r_A_v4
    snap_set xray_router   r_T_v6
    snap_set xray_router   r_A_v6
    snap_set xray_clients  c_bypass_dst_v4
    snap_set xray_clients  c_bypass_src_v4
    snap_set xray_clients  c_bypass_dst_v6
    snap_set xray_clients  c_bypass_src_v6
    snap_set xray_clients  c_T_dst_v4
    snap_set xray_clients  c_A_dst_v4
    snap_set xray_clients  c_T_dst_v6
    snap_set xray_clients  c_A_dst_v6
} > "$LAST_GOOD.new.$$"
mv "$LAST_GOOD.new.$$" "$LAST_GOOD"

if [ "$mode" = "--dry-run" ]; then
    for s in \
        r_T_v4 r_A_v4 r_T_v6 r_A_v6 \
        c_bypass_dst_v4 c_bypass_src_v4 c_bypass_dst_v6 c_bypass_src_v6 \
        c_T_dst_v4 c_A_dst_v4 c_T_dst_v6 c_A_dst_v6
    do
        [ -f "$WORK/$s" ] || continue
        n=$(wc -l < "$WORK/$s")
        log "$s would have $n elements"
    done
    exit 0
fi

build_add() {
    table="$1"
    name="$2"
    src="$3"
    if ! nft list set inet "$table" "$name" >/dev/null 2>&1; then
        printf '[update-sets] skip: set inet %s %s absent in kernel (run apply-nft first)\n' \
            "$table" "$name" >&2
        return 0
    fi
    printf 'flush set inet %s %s\n' "$table" "$name"
    [ -s "$src" ] || return 0
    printf 'add element inet %s %s { ' "$table" "$name"
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
    build_add xray_router   r_T_v6          "$WORK/r_T_v6"
    build_add xray_router   r_A_v6          "$WORK/r_A_v6"
    build_add xray_clients  c_bypass_dst_v4 "$WORK/c_bypass_dst_v4"
    build_add xray_clients  c_bypass_src_v4 "$WORK/c_bypass_src_v4"
    build_add xray_clients  c_bypass_dst_v6 "$WORK/c_bypass_dst_v6"
    build_add xray_clients  c_bypass_src_v6 "$WORK/c_bypass_src_v6"
    build_add xray_clients  c_T_dst_v4      "$WORK/c_T_dst_v4"
    build_add xray_clients  c_A_dst_v4      "$WORK/c_A_dst_v4"
    build_add xray_clients  c_T_dst_v6      "$WORK/c_T_dst_v6"
    build_add xray_clients  c_A_dst_v6      "$WORK/c_A_dst_v6"
} > "$WORK/apply.nft"

nft -c -f "$WORK/apply.nft" || die 'nft -c rejected the generated script'
if ! nft -f "$WORK/apply.nft"; then
    warn 'nft -f failed; attempting automatic restore from last-good-sets.txt'
    if restore_last_good; then
        die 'nft -f failed; automatic restore succeeded, previous set contents restored'
    else
        die 'nft -f failed and automatic restore also failed; state may be partial'
    fi
fi

for s in \
    r_T_v4 r_A_v4 r_T_v6 r_A_v6 \
    c_bypass_dst_v4 c_bypass_src_v4 c_bypass_dst_v6 c_bypass_src_v6 \
    c_T_dst_v4 c_A_dst_v4 c_T_dst_v6 c_A_dst_v6
do
    [ -f "$WORK/$s" ] || continue
    n=$(wc -l < "$WORK/$s" | awk '{print $1}')
    log "$s applied ($n elements)"
done
date +'%Y-%m-%dT%H:%M:%S%z' > "$STATE/last-update-sets.txt"
log 'OK'
