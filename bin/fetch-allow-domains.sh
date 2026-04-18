#!/bin/sh
# fetch-allow-domains.sh
#
# Download curated domain lists from a third-party provider and write them to
# /etc/xray/lists/remote/allow-<target>.txt. merge-lists.sh picks up those
# files in addition to local/ and remote/ sources.
#
# The provider base URL is configured in /etc/xray/secret.env as
# ALLOW_DOMAINS_BASE (kept private). If unset or empty, this script is a
# no-op. The path suffixes below are the public, git-tracked portion of the
# integration: they describe which upstream files map to which local list.
#
# Multiple suffixes may point at the same target list — they are
# concatenated into one allow-<target> file. Adjust ITEMS to extend
# coverage. Keep target names aligned with the naming scheme used by
# merge-lists.sh (c-T-domains.txt, c-A-domains.txt, ...).

set -eu

XRAY_ROOT="/etc/xray"
R="$XRAY_ROOT/lists/remote"
STATE="$XRAY_ROOT/state"

log()  { printf '[fetch-allow] %s\n' "$*"; }
warn() { printf '[fetch-allow][WARN] %s\n' "$*" >&2; }
die()  { printf '[fetch-allow][FATAL] %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1091
[ -r "$XRAY_ROOT/secret.env" ] && . "$XRAY_ROOT/secret.env"

BASE="${ALLOW_DOMAINS_BASE-}"
if [ -z "$BASE" ]; then
    log 'ALLOW_DOMAINS_BASE not set; skipping'
    exit 0
fi
BASE="${BASE%/}"

mkdir -p "$R" "$STATE"

if command -v curl >/dev/null 2>&1; then DL='curl -fsSL -o'
elif command -v wget >/dev/null 2>&1; then DL='wget -q -O'
else die 'neither curl nor wget present'
fi

# pairs: <target-list-name> <path-suffix-relative-to-BASE>
# All suffixes mapped to the same target are concatenated.
ITEMS='
c-T-domains.txt Russia/inside-raw.lst
c-T-domains.txt Services/google_ai.lst
c-T-domains.txt Services/hdrezka.lst
'

# Iterate unique targets, concatenating all suffixes into one dst.
targets=$(echo "$ITEMS" | awk 'NF==2 {print $1}' | sort -u)

for name in $targets; do
    dst="$R/allow-$name"
    tmp="$R/.allow-$name.new.$$"
    : > "$tmp"
    any_ok=0
    # All suffixes pointing at this target
    for suffix in $(echo "$ITEMS" | awk -v t="$name" 'NF==2 && $1==t {print $2}'); do
        url="$BASE/$suffix"
        part="$R/.allow-$name.part.$$"
        if $DL "$part" "$url"; then
            printf '\n# --- %s ---\n' "$suffix" >> "$tmp"
            cat "$part" >> "$tmp"
            rm -f "$part"
            any_ok=1
            log "  fetched $suffix"
        else
            rm -f "$part"
            warn "  fetch failed: $url"
        fi
    done
    if [ "$any_ok" = 1 ] && [ -s "$tmp" ]; then
        mv "$tmp" "$dst"
        log "allow-$name: $(wc -l < "$dst" | awk '{print $1}') lines total"
    else
        rm -f "$tmp"
        warn "all fetches failed for $name; keeping previous"
    fi
done

"$XRAY_ROOT/bin/update-sets.sh" || warn 'update-sets.sh failed; merged files may be stale'

date +'%Y-%m-%dT%H:%M:%S%z' > "$STATE/last-fetch-allow-domains.txt"
log 'OK'
