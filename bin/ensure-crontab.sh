#!/bin/sh
# ensure-crontab.sh
#
# Install or migrate the managed Xray cron block into /etc/crontabs/root
# without disturbing unrelated jobs.

set -eu

XRAY_ROOT="${XRAY_ROOT:-/etc/xray}"
CRONTAB_FILE="${CRONTAB_FILE:-/etc/crontabs/root}"
CRON_INITD="${CRON_INITD:-/etc/init.d/cron}"
STATE_DIR="${STATE_DIR:-$XRAY_ROOT/state}"
BEGIN_MARK='# >>> XRAY MANAGED BLOCK >>>'
END_MARK='# <<< XRAY MANAGED BLOCK <<<'

MODE=install
RELOAD=0

usage() {
    cat <<'EOF' >&2
usage: ensure-crontab.sh [--check|--install|--migrate] [--reload]
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE=check ;;
        --install) MODE=install ;;
        --migrate) MODE=migrate ;;
        --reload) RELOAD=1 ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
    shift
done

log()  { printf '[cron] %s\n' "$*"; }
warn() { printf '[cron][WARN] %s\n' "$*" >&2; }
die()  { printf '[cron][FATAL] %s\n' "$*" >&2; exit 1; }

mkdir -p "$STATE_DIR"
mkdir -p "$(dirname "$CRONTAB_FILE")"
[ -e "$CRONTAB_FILE" ] || : > "$CRONTAB_FILE"

WORK=$(mktemp -d "$STATE_DIR/cron.XXXXXX") || die 'mktemp failed'
trap 'rm -rf "$WORK"' EXIT INT TERM

stripped="$WORK/root.without-managed"
legacy_removed="$WORK/root.without-legacy"
candidate="$WORK/root.candidate"

strip_managed_block() {
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
        $0 == begin {skip=1; next}
        $0 == end {skip=0; next}
        !skip {print}
    ' "$CRONTAB_FILE"
}

strip_managed_block > "$stripped"

has_managed_block() {
    grep -Fxq "$BEGIN_MARK" "$CRONTAB_FILE" && grep -Fxq "$END_MARK" "$CRONTAB_FILE"
}

has_legacy_xray_lines() {
    awk '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*$/ {next}
        /\/etc\/xray\/bin\// {found=1}
        END {exit(found ? 0 : 1)}
    ' "$stripped"
}

write_managed_block() {
    cat <<'EOF'
# >>> XRAY MANAGED BLOCK >>>
# Refresh nft sets from merged lists every 20 minutes
*/20 * * * *   /etc/xray/bin/update-sets.sh            >> /tmp/xray-cron.log 2>&1

# Bound hot /tmp logs every 10 minutes (silent; details go to syslog if trimmed)
*/10 * * * *   /etc/xray/bin/cap-volatile-logs.sh      >/dev/null 2>&1

# Pull remote lists every 4 hours; update-sets runs as its tail
17 */4 * * *   /etc/xray/bin/fetch-remote-lists.sh     >> /tmp/xray-cron.log 2>&1

# Pull allow-domains provider lists every 6 hours (no-op if unset)
43 */6 * * *   /etc/xray/bin/fetch-allow-domains.sh    >> /tmp/xray-cron.log 2>&1

# Pull templates/helpers/nft rules from GitHub once a day at 04:23
23 4 * * *     /etc/xray/bin/update-managed-stack.sh   >> /tmp/xray-cron.log 2>&1

# Pull fresh geosite.dat/geoip.dat once a week (Sunday 05:07)
7 5 * * 0      /etc/xray/bin/update-assets.sh          >> /tmp/xray-cron.log 2>&1
# <<< XRAY MANAGED BLOCK <<<
EOF
}

build_candidate_from() {
    src="$1"
    : > "$candidate"
    cat "$src" > "$candidate"
    if [ -s "$candidate" ]; then
        printf '\n' >> "$candidate"
    fi
    write_managed_block >> "$candidate"
}

backup_current() {
    ts=$(date +%Y%m%d-%H%M%S)
    cp -p "$CRONTAB_FILE" "$STATE_DIR/crontab-root.${ts}.bak"
}

reload_cron_if_needed() {
    [ "$RELOAD" = 1 ] || return 0
    [ -x "$CRON_INITD" ] || {
        warn "cron init script not found: $CRON_INITD"
        return 0
    }
    "$CRON_INITD" reload >/dev/null 2>&1 || "$CRON_INITD" restart >/dev/null 2>&1 || warn 'cron reload failed'
}

case "$MODE" in
    check)
        if has_legacy_xray_lines; then
            warn 'legacy /etc/xray/bin cron lines exist outside the managed block'
            exit 11
        fi
        if has_managed_block; then
            log 'managed block present'
            exit 0
        fi
        warn 'managed block missing'
        exit 10
        ;;
    install)
        if has_legacy_xray_lines; then
            warn 'legacy /etc/xray/bin cron lines exist outside the managed block; refusing to add duplicates'
            warn 'rerun with --migrate to replace those legacy lines with the managed block'
            exit 11
        fi
        build_candidate_from "$stripped"
        ;;
    migrate)
        awk '
            /^[[:space:]]*#/ {print; next}
            /^[[:space:]]*$/ {print; next}
            /\/etc\/xray\/bin\// {next}
            {print}
        ' "$stripped" > "$legacy_removed"
        build_candidate_from "$legacy_removed"
        ;;
esac

backup_current
mv "$candidate" "$CRONTAB_FILE"
chmod 600 "$CRONTAB_FILE"
reload_cron_if_needed
log 'managed cron block installed'
