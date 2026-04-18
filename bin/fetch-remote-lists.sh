#!/bin/sh
# fetch-remote-lists.sh
#
# Download remote lists into /etc/xray/lists/remote atomically, then invoke
# update-sets.sh to rebuild merged lists and refresh nft set elements.
#
# Remote list URLs come from /etc/xray/secret.env (shell vars). For every list
# name in the standard naming scheme, you may define:
#   LISTS_R_T_IPV4_URL=...
#   LISTS_R_T_DOMAINS_URL=...
#   ...etc
# Any variable that is empty or unset => that remote file is cleared.

set -eu

XRAY_ROOT="/etc/xray"
R="$XRAY_ROOT/lists/remote"
STATE="$XRAY_ROOT/state"

log()  { printf '[fetch-remote] %s\n' "$*"; }
warn() { printf '[fetch-remote][WARN] %s\n' "$*" >&2; }
die()  { printf '[fetch-remote][FATAL] %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1091
[ -r "$XRAY_ROOT/secret.env" ] && . "$XRAY_ROOT/secret.env"

mkdir -p "$R" "$STATE"

if command -v curl >/dev/null 2>&1; then DL='curl -fsSL -o'
elif command -v wget >/dev/null 2>&1; then DL='wget -q -O'
else die 'neither curl nor wget present'
fi

# pairs: <filename> <env-var>
FETCH='
r-T-ipv4.txt    LISTS_R_T_IPV4_URL
r-A-ipv4.txt    LISTS_R_A_IPV4_URL
r-T-domains.txt LISTS_R_T_DOMAINS_URL
r-A-domains.txt LISTS_R_A_DOMAINS_URL
c-D-ipv4.txt    LISTS_C_D_IPV4_URL
c-T-ipv4.txt    LISTS_C_T_IPV4_URL
c-A-ipv4.txt    LISTS_C_A_IPV4_URL
c-D-domains.txt LISTS_C_D_DOMAINS_URL
c-T-domains.txt LISTS_C_T_DOMAINS_URL
c-A-domains.txt LISTS_C_A_DOMAINS_URL
'

# iterate pairs
echo "$FETCH" | awk 'NF==2 {print $1"\t"$2}' | while IFS="	" read -r name var; do
    eval "url=\${$var-}"
    dst="$R/$name"
    if [ -z "$url" ]; then
        : > "$dst"
        continue
    fi
    tmp="$R/.${name}.new.$$"
    if $DL "$tmp" "$url"; then
        mv "$tmp" "$dst"
        log "fetched $name ($(wc -l < "$dst" | awk '{print $1}') lines)"
    else
        rm -f "$tmp"
        warn "download failed for $name ($url); keeping previous"
    fi
done

# Kick off set refresh. If it fails, do not fail the whole run — remote list
# download itself succeeded.
"$XRAY_ROOT/bin/update-sets.sh" || warn 'update-sets.sh failed; merged files OK, sets may be stale'

date +'%Y-%m-%dT%H:%M:%S%z' > "$STATE/last-fetch-remote.txt"
log 'OK'
