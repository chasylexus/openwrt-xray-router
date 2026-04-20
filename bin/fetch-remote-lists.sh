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

WORK=$(mktemp -d "$STATE/fetch-remote.XXXXXX") || die 'mktemp failed'
BACKUP="$WORK/backup"
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$BACKUP"

backup_once() {
    name="$1"
    dst="$R/$name"
    if [ -e "$BACKUP/$name" ] || [ -e "$BACKUP/$name.absent" ]; then
        return 0
    fi
    if [ -e "$dst" ]; then
        cp -p "$dst" "$BACKUP/$name"
    else
        : > "$BACKUP/$name.absent"
    fi
}

restore_one() {
    name="$1"
    dst="$R/$name"
    if [ -e "$BACKUP/$name" ]; then
        cp -p "$BACKUP/$name" "$dst"
    else
        rm -f "$dst"
    fi
}

note_changed() {
    name="$1"
    case " $CHANGED " in
        *" $name "*) : ;;
        *) CHANGED="${CHANGED:+$CHANGED }$name" ;;
    esac
}

rollback_remote_files() {
    [ -n "${CHANGED:-}" ] || return 0
    warn 'rolling remote list files back to previous versions'
    for name in $CHANGED; do
        restore_one "$name"
    done
    "$XRAY_ROOT/bin/merge-lists.sh" >/dev/null 2>&1 \
        || warn 'merge-lists.sh failed while rebuilding merged lists after rollback'
}

CHANGED=""
FETCH_TAB="$WORK/fetch.tsv"

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
echo "$FETCH" | awk 'NF==2 {print $1"\t"$2}' > "$FETCH_TAB"
while IFS="	" read -r name var; do
    eval "url=\${$var-}"
    dst="$R/$name"
    if [ -z "$url" ]; then
        backup_once "$name"
        : > "$dst"
        note_changed "$name"
        continue
    fi
    tmp="$WORK/${name}.new"
    if $DL "$tmp" "$url"; then
        backup_once "$name"
        mv "$tmp" "$dst"
        note_changed "$name"
        log "fetched $name ($(wc -l < "$dst" | awk '{print $1}') lines)"
    else
        rm -f "$tmp"
        warn "download failed for $name ($url); keeping previous"
    fi
done < "$FETCH_TAB"

if ! "$XRAY_ROOT/bin/update-sets.sh"; then
    rollback_remote_files
    die 'update-sets.sh failed after remote refresh; previous remote files restored'
fi

date +'%Y-%m-%dT%H:%M:%S%z' > "$STATE/last-fetch-remote.txt"
log 'OK'
