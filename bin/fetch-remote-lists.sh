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
# Any variable that is set to an empty string => that remote file is cleared.
#
# Special case: per-IP forced-outbound lists for the nft stage can default to
# the pinned repository when their vars are UNSET:
#   LISTS_C_T_DST_V4_URL  -> $REPO_RAW/lists/c-T-dst-v4.txt
#   LISTS_C_A_DST_V4_URL  -> $REPO_RAW/lists/c-A-dst-v4.txt
# This keeps the "edit list in repo -> push -> cron pulls from raw GitHub"
# workflow zero-touch on the router for nft-stage IP routing.

set -eu

XRAY_ROOT="/etc/xray"
R="$XRAY_ROOT/lists/remote"
STATE="$XRAY_ROOT/state"
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

log()  { printf '[fetch-remote] %s\n' "$*"; }
warn() { printf '[fetch-remote][WARN] %s\n' "$*" >&2; }
die()  { printf '[fetch-remote][FATAL] %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1091
. "$SELF_DIR/load-env.sh"
xray_load_env

mkdir -p "$R" "$STATE"

if command -v curl >/dev/null 2>&1; then DL='curl -fsSL -o'
elif command -v wget >/dev/null 2>&1; then DL='wget -q -O'
elif command -v uclient-fetch >/dev/null 2>&1; then DL='uclient-fetch -O'
else die 'no downloader present (curl, wget, uclient-fetch)'
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

repo_join() {
    rel="$1"
    printf '%s/%s\n' "${REPO_RAW%/}" "${rel#/}"
}

resolve_url() {
    var="$1"
    default_rel="${2:-}"

    if eval "[ \"\${$var+x}\" = x ]"; then
        eval "url=\${$var}"
        [ -n "$url" ] || {
            printf '\n'
            return 0
        }
        case "$url" in
            http://*|https://*)
                printf '%s\n' "$url"
                ;;
            *)
                [ -n "${REPO_RAW-}" ] || die "$var is relative but REPO_RAW is unset"
                repo_join "$url"
                ;;
        esac
        return 0
    fi

    if [ -n "$default_rel" ] && [ -n "${REPO_RAW-}" ]; then
        repo_join "$default_rel"
        return 0
    fi

    printf '\n'
}

# triples: <filename> <env-var> <repo-default-relative-path>
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
c-T-dst-v4.txt  LISTS_C_T_DST_V4_URL  lists/c-T-dst-v4.txt
c-A-dst-v4.txt  LISTS_C_A_DST_V4_URL  lists/c-A-dst-v4.txt
'

# iterate pairs
echo "$FETCH" | awk 'NF>=2 {print $1"\t"$2"\t"$3}' > "$FETCH_TAB"
tab=$(printf '\t')
while IFS="$tab" read -r name var default_rel; do
    url=$(resolve_url "$var" "$default_rel")
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
