#!/bin/sh
# bootstrap-xray-v2.sh
#
# Устанавливает/обновляет managed-структуру /etc/xray, скачивает helper-скрипты,
# ставит init.d/xray и managed cron block. По умолчанию работает в безопасном
# ensure-режиме: ничего не ломает на уже настроенном роутере и не делает
# принудительный full apply. Флаг --force-init запускает полный bootstrap/apply
# после того как secret.env уже готов.
#
# Usage:
#   sh bootstrap-xray-v2.sh [--force-init] <REPO_RAW_URL>
#
# REPO_RAW_URL — базовый URL до raw-файлов репозитория, например:
#   https://raw.githubusercontent.com/you/openwrt-xray-router/main
#
# Идемпотентен: повторный запуск обновляет managed-файлы, но не трогает
# secret.env и lists/local.

set -eu

MODE="ensure"
REPO_RAW=""

usage() {
    echo "usage: $0 [--force-init] <REPO_RAW_URL>" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --force-init) MODE="force-init" ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            usage
            exit 2
            ;;
        *)
            [ -z "$REPO_RAW" ] || {
                usage
                exit 2
            }
            REPO_RAW=$1
            ;;
    esac
    shift
done

[ -n "$REPO_RAW" ] || {
    usage
    exit 2
}

XRAY_ROOT="/etc/xray"
INITD="/etc/init.d/xray"

log() { printf '[bootstrap] %s\n' "$*"; }
die() { printf '[bootstrap][FATAL] %s\n' "$*" >&2; exit 1; }

# ------- 1. preflight checks ---------------------------------------------

need_bin() {
    command -v "$1" >/dev/null 2>&1 || die "required binary not found: $1"
}

log 'checking required binaries'
need_bin sh
need_bin awk
need_bin sed
need_bin grep
need_bin sort
need_bin uniq
need_bin nft
need_bin ip
need_bin nslookup
need_bin uci

# wget OR curl — достаточно одного
if command -v curl >/dev/null 2>&1; then
    DL='curl -fsSL -o'
elif command -v wget >/dev/null 2>&1; then
    DL='wget -q -O'
else
    die 'neither curl nor wget present; cannot download files'
fi

# Xray binary
[ -x /usr/local/xray/xray ] || die '/usr/local/xray/xray missing or not executable'

# ------- 2. layout --------------------------------------------------------

log 'creating directories'
mkdir -p "$XRAY_ROOT/config.d"
mkdir -p "$XRAY_ROOT/nft.d"
mkdir -p "$XRAY_ROOT/lists/local"
mkdir -p "$XRAY_ROOT/lists/remote"
mkdir -p "$XRAY_ROOT/lists/merged"
mkdir -p "$XRAY_ROOT/templates/xray"
mkdir -p "$XRAY_ROOT/templates/nft"
mkdir -p "$XRAY_ROOT/templates/dnsmasq"
mkdir -p "$XRAY_ROOT/state"
mkdir -p "$XRAY_ROOT/bin"
mkdir -p "$XRAY_ROOT/dnsmasq.d"

chmod 700 "$XRAY_ROOT"
chmod 700 "$XRAY_ROOT/state"

# ------- 3. download helper scripts --------------------------------------

BIN_FILES='
render-template.sh
load-env.sh
ensure-crontab.sh
apply-iprules.sh
apply-nft.sh
run-xray.sh
merge-lists.sh
update-sets.sh
update-all.sh
update-assets.sh
cap-volatile-logs.sh
update-managed-stack.sh
fetch-remote-lists.sh
fetch-allow-domains.sh
'

log 'downloading helper scripts'
for f in $BIN_FILES; do
    tmp="$XRAY_ROOT/bin/.${f}.new.$$"
    if ! $DL "$tmp" "$REPO_RAW/bin/$f"; then
        rm -f "$tmp"
        die "download failed: bin/$f"
    fi
    # non-empty sanity
    [ -s "$tmp" ] || { rm -f "$tmp"; die "empty download: bin/$f"; }
    head -1 "$tmp" | grep -q '^#!' || { rm -f "$tmp"; die "not a shell script: bin/$f"; }
    mv "$tmp" "$XRAY_ROOT/bin/$f"
    chmod 755 "$XRAY_ROOT/bin/$f"
done

# ------- 4. download stub lists (only if missing locally) ----------------

LIST_FILES='
r-T-ipv4.txt r-A-ipv4.txt
r-T-domains.txt r-A-domains.txt
c-bypass-dst-v4.txt c-bypass-src-v4.txt
c-T-dst-v4.txt c-A-dst-v4.txt
c-D-ipv4.txt c-T-ipv4.txt c-A-ipv4.txt
c-D-domains.txt c-T-domains.txt c-A-domains.txt
'
log 'seeding lists/local with starter files (only missing ones)'
for f in $LIST_FILES; do
    [ -e "$XRAY_ROOT/lists/local/$f" ] && continue
    tmp="$XRAY_ROOT/lists/local/.${f}.new.$$"
    if $DL "$tmp" "$REPO_RAW/lists/$f"; then
        mv "$tmp" "$XRAY_ROOT/lists/local/$f"
    else
        rm -f "$tmp"
        : > "$XRAY_ROOT/lists/local/$f"
    fi
done

# ------- 5. init.d/xray ---------------------------------------------------

log 'installing /etc/init.d/xray'
tmp="${INITD}.new.$$"
if ! $DL "$tmp" "$REPO_RAW/init.d/xray"; then
    rm -f "$tmp"
    die 'download failed: init.d/xray'
fi
head -1 "$tmp" | grep -q '^#!' || { rm -f "$tmp"; die 'init.d/xray is not a shell script'; }
mv "$tmp" "$INITD"
chmod 755 "$INITD"

# ------- 6. secret.env.example ------------------------------------------

if [ ! -e "$XRAY_ROOT/secret.env.example" ]; then
    tmp="$XRAY_ROOT/.secret.env.example.new.$$"
    if $DL "$tmp" "$REPO_RAW/examples/secret.env.example"; then
        mv "$tmp" "$XRAY_ROOT/secret.env.example"
    else
        rm -f "$tmp"
        log 'WARN: could not fetch secret.env.example'
    fi
fi

# ------- 7. pin REPO_RAW in /etc/xray/repo.env ---------------------------

printf 'REPO_RAW=%s\n' "$REPO_RAW" > "$XRAY_ROOT/repo.env"
chmod 600 "$XRAY_ROOT/repo.env"

# ------- 8. disarm rc.local orchestration --------------------------------

# Делаем явный маркер, чтобы если в rc.local что-то связанное с xray/nft —
# пользователь видел предупреждение при bootstrap.
if grep -qE 'xray|nftset|nft .*xray' /etc/rc.local 2>/dev/null; then
    log 'WARN: /etc/rc.local contains xray/nft related lines — review and remove them manually.'
    log 'This repo expects /etc/init.d/xray to be the SINGLE orchestrator.'
fi

# ------- 9. done ---------------------------------------------------------

log 'ensuring cron service'
if [ -x /etc/init.d/cron ]; then
    /etc/init.d/cron enable >/dev/null 2>&1 || log 'WARN: failed to enable cron'
    /etc/init.d/cron start  >/dev/null 2>&1 || true
else
    log 'WARN: /etc/init.d/cron missing; cron not enabled'
fi

log 'ensuring managed cron block'
if [ "$MODE" = "force-init" ]; then
    if ! "$XRAY_ROOT/bin/ensure-crontab.sh" --migrate --reload; then
        die 'failed to migrate/install managed cron block'
    fi
else
    if ! "$XRAY_ROOT/bin/ensure-crontab.sh" --install --reload; then
        log 'WARN: managed cron block not auto-installed (likely legacy xray cron lines exist outside the managed block)'
        log 'WARN: rerun with --force-init to migrate those lines automatically'
    fi
fi

secret_ready=0
if [ -r "$XRAY_ROOT/secret.env" ]; then
    # shellcheck disable=SC1091
    . "$XRAY_ROOT/bin/load-env.sh"
    if xray_load_env >/dev/null 2>&1 && xray_env_stack_ready >/dev/null 2>&1; then
        secret_ready=1
    else
        log 'secret.env exists, but is not yet complete/valid for full apply'
    fi
else
    log 'secret.env missing (normal on first bootstrap)'
fi

log ''
log "bootstrap ${MODE} OK"

if [ "$MODE" = "force-init" ]; then
    if [ "$secret_ready" -eq 1 ]; then
        log 'running full initialization chain'
        "$XRAY_ROOT/bin/update-all.sh" || die 'update-all failed'
        /etc/init.d/xray enable >/dev/null 2>&1 || log 'WARN: failed to enable xray service'
        if ! /etc/init.d/xray status >/dev/null 2>&1; then
            /etc/init.d/xray start >/dev/null 2>&1 || die 'xray start failed after force-init'
        fi
        log 'force-init completed: config rendered, lists fetched, assets checked, service ready'
        exit 0
    fi

    log 'managed files and cron are ready, but full apply was skipped until secret.env is complete'
    log 'Fill /etc/xray/secret.env and rerun the same --force-init command'
    exit 0
fi

log ''
log 'Ensure mode summary:'
log '  - managed files refreshed'
log '  - repo.env pinned'
log '  - managed cron block installed when safe'
log '  - no forced xray apply/start was performed'
if [ "$secret_ready" -eq 1 ]; then
    log 'secret.env already looks complete; rerun with --force-init if you want bootstrap to render/apply/start automatically'
else
    log 'Next steps:'
    log '  1. cp /etc/xray/secret.env.example /etc/xray/secret.env'
    log '  2. vi /etc/xray/secret.env   # fill GEOSITE/GEOIP URLs and either T_VLESS_URL/A_VLESS_URL or split T_*/A_* vars'
    log '  3. chmod 600 /etc/xray/secret.env'
    log '  4. rerun bootstrap with --force-init'
fi
