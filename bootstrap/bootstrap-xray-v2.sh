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
#   sh bootstrap-xray-v2.sh [--force-init] [REPO_RAW_URL]
#
# REPO_RAW_URL — optional override of the built-in raw repo base URL.
# Default:
#   https://raw.githubusercontent.com/chasylexus/openwrt-xray-router/refs/heads/main
#
# Идемпотентен: повторный запуск обновляет managed-файлы, но не трогает
# secret.env и lists/local.

set -eu

MODE="ensure"
DEFAULT_REPO_RAW="https://raw.githubusercontent.com/chasylexus/openwrt-xray-router/refs/heads/main"
REPO_RAW="$DEFAULT_REPO_RAW"
REPO_RAW_OVERRIDDEN=0
XRAY_ROOT="/etc/xray"
INITD="/etc/init.d/xray"

log() { printf '[bootstrap] %s\n' "$*"; }
die() { printf '[bootstrap][FATAL] %s\n' "$*" >&2; exit 1; }

usage() {
    echo "usage: $0 [--force-init] [REPO_RAW_URL]" >&2
}

is_interactive() {
    [ -t 0 ] && [ -t 1 ]
}

normalize_repo_raw() {
    printf '%s' "$1" | sed 's#^[[:space:]]*##; s#[[:space:]]*$##; s#/*$##'
}

prompt_line() {
    prompt="$1"
    default="${2:-}"

    if [ -n "$default" ]; then
        printf '%s [%s]: ' "$prompt" "$default" >/dev/tty
    else
        printf '%s: ' "$prompt" >/dev/tty
    fi

    IFS= read -r reply </dev/tty || return 1
    if [ -n "$reply" ]; then
        printf '%s\n' "$reply"
    else
        printf '%s\n' "$default"
    fi
}

shell_quote_single() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

upsert_env_var() {
    file="$1"
    key="$2"
    value="$3"
    quoted=$(shell_quote_single "$value")
    tmp="${file}.new.$$"

    awk -v key="$key" -v quoted="$quoted" '
        BEGIN { done = 0 }
        $0 ~ ("^" key "=") {
            print key "=" quoted
            done = 1
            next
        }
        { print }
        END {
            if (!done) {
                print key "=" quoted
            }
        }
    ' "$file" > "$tmp" || {
        rm -f "$tmp"
        die "failed to update $key in $file"
    }

    mv "$tmp" "$file"
}

ensure_secret_env_file() {
    if [ -r "$XRAY_ROOT/secret.env" ]; then
        return 0
    fi

    [ -r "$XRAY_ROOT/secret.env.example" ] || return 1

    cp -p "$XRAY_ROOT/secret.env.example" "$XRAY_ROOT/secret.env"
    chmod 600 "$XRAY_ROOT/secret.env"
    log 'created /etc/xray/secret.env from secret.env.example'
}

load_secret_state() {
    # shellcheck disable=SC1091
    . "$XRAY_ROOT/bin/load-env.sh"
    if xray_load_env >/dev/null 2>&1; then
        SECRET_LOAD_OK=1
    else
        SECRET_LOAD_OK=0
    fi
}

outbound_ready() {
    prefix="$1"
    if [ "${SECRET_LOAD_OK:-0}" -ne 1 ]; then
        return 1
    fi
    xray_env_require_outbound "$prefix" >/dev/null 2>&1
}

current_env_value() {
    name="$1"
    eval "printf '%s\\n' \"\${$name:-}\""
}

prompt_vless_urls_if_needed() {
    is_interactive || return 0
    ensure_secret_env_file || return 0

    XRAY_SECRET_ENV_FILE="$XRAY_ROOT/secret.env"
    XRAY_REPO_ENV_FILE="$XRAY_ROOT/repo.env"
    SECRET_LOAD_OK=0
    load_secret_state

    t_value=""
    if outbound_ready T; then
        t_value=$(current_env_value T_VLESS_URL)
    fi

    if ! outbound_ready T; then
        printf '\n%s\n' 'T outbound is not configured yet.' >/dev/tty
        printf '%s\n' 'Neutral example:' >/dev/tty
        printf '%s\n' '  vless://00000000-0000-0000-0000-000000000000@example.com:443?security=reality&sni=www.microsoft.com&fp=chrome&pbk=PUBLIC_KEY&sid=deadbeef&type=tcp&flow=xtls-rprx-vision#T' >/dev/tty
        reply=$(prompt_line 'Enter T_VLESS_URL (leave blank to skip for now)' '')
        if [ -n "$reply" ]; then
            upsert_env_var "$XRAY_ROOT/secret.env" T_VLESS_URL "$reply"
            log 'stored T_VLESS_URL in /etc/xray/secret.env'
            t_value=$reply
        fi
    fi

    XRAY_SECRET_ENV_FILE="$XRAY_ROOT/secret.env"
    XRAY_REPO_ENV_FILE="$XRAY_ROOT/repo.env"
    SECRET_LOAD_OK=0
    load_secret_state

    if ! outbound_ready A; then
        printf '\n%s\n' 'A outbound is not configured yet.' >/dev/tty
        printf '%s\n' 'Neutral example:' >/dev/tty
        printf '%s\n' '  vless://00000000-0000-0000-0000-000000000000@example.net:443?security=reality&sni=www.apple.com&fp=chrome&pbk=PUBLIC_KEY&sid=feedface&type=tcp&flow=xtls-rprx-vision#A' >/dev/tty
        if [ -n "$t_value" ]; then
            printf '%s\n' 'Press Enter to reuse the same VLESS URL as T.' >/dev/tty
        fi
        reply=$(prompt_line 'Enter A_VLESS_URL (leave blank to skip for now)' '')
        if [ -z "$reply" ] && [ -n "$t_value" ]; then
            reply=$t_value
        fi
        if [ -n "$reply" ]; then
            upsert_env_var "$XRAY_ROOT/secret.env" A_VLESS_URL "$reply"
            log 'stored A_VLESS_URL in /etc/xray/secret.env'
        fi
    fi
}

PKG_MGR=""
PKG_UPDATED=0
DL=""

pkg_init() {
    if command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
    elif command -v opkg >/dev/null 2>&1; then
        PKG_MGR="opkg"
    else
        die 'neither apk nor opkg present; cannot install dependencies'
    fi
}

pkg_update_once() {
    [ "$PKG_UPDATED" = 0 ] || return 0
    case "$PKG_MGR" in
        apk)
            log 'updating apk package index'
            apk update >/dev/null
            ;;
        opkg)
            log 'updating opkg package index'
            opkg update >/dev/null
            ;;
    esac
    PKG_UPDATED=1
}

pkg_is_installed() {
    pkg="$1"
    case "$PKG_MGR" in
        apk)
            apk info -e "$pkg" >/dev/null 2>&1
            ;;
        opkg)
            opkg status "$pkg" 2>/dev/null | grep -q '^Status: .* installed'
            ;;
    esac
}

pkg_install() {
    pkg_update_once
    case "$PKG_MGR" in
        apk) apk add "$@" ;;
        opkg) opkg install "$@" ;;
    esac
}

pkg_remove() {
    case "$PKG_MGR" in
        apk) apk del "$@" ;;
        opkg) opkg remove "$@" ;;
    esac
}

xray_binary_present() {
    if [ -x /usr/local/xray/xray ]; then
        return 0
    fi

    if command -v xray >/dev/null 2>&1; then
        mkdir -p /usr/local/xray
        ln -sf "$(command -v xray)" /usr/local/xray/xray
        [ -x /usr/local/xray/xray ] || return 1
        return 0
    fi

    return 1
}

pick_downloader() {
    if command -v curl >/dev/null 2>&1; then
        DL='curl -4 -fsSL -o'
        return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        DL='wget -4 -q -O'
        return 0
    fi
    if command -v uclient-fetch >/dev/null 2>&1; then
        DL='uclient-fetch -4 -O'
        return 0
    fi
    return 1
}

ensure_downloader_if_needed() {
    pick_downloader && return 0

    if [ "$MODE" != "force-init" ]; then
        die 'no downloader found (curl, wget, uclient-fetch); rerun with --force-init so bootstrap can install one'
    fi

    pkg_init
    log 'installing downloader dependency (curl)'
    pkg_install ca-bundle curl >/dev/null || die 'failed to install curl'
    pick_downloader || die 'downloader still missing after installing curl'
}

critical_preroute_ready() {
    command -v nft >/dev/null 2>&1 &&
    command -v ip  >/dev/null 2>&1 &&
    command -v uci >/dev/null 2>&1 &&
    command -v nslookup >/dev/null 2>&1 &&
    xray_binary_present
}

warn_or_install_command() {
    cmd="$1"
    pkg="$2"
    reason="$3"

    command -v "$cmd" >/dev/null 2>&1 && return 0

    if [ "$MODE" = "force-init" ]; then
        log "installing $pkg for $reason"
        pkg_install "$pkg" >/dev/null || die "failed to install $pkg"
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd still missing after installing $pkg"
        return 0
    fi

    log "WARN: missing $cmd ($reason); rerun with --force-init to install $pkg"
    return 1
}

ensure_dnsmasq_full() {
    pkg_is_installed dnsmasq-full && return 0

    if [ "$MODE" != "force-init" ]; then
        log 'WARN: dnsmasq-full is not installed; rerun with --force-init to migrate/install it'
        return 1
    fi

    log 'ensuring dnsmasq-full with nftset support'
    if pkg_is_installed dnsmasq; then
        log 'replacing dnsmasq with dnsmasq-full'
        pkg_remove dnsmasq >/dev/null || die 'failed to remove dnsmasq before installing dnsmasq-full'
    fi

    pkg_install dnsmasq-full >/dev/null || die 'failed to install dnsmasq-full'
    pkg_is_installed dnsmasq-full || die 'dnsmasq-full still not installed after package step'
}

ensure_xray_binary() {
    if xray_binary_present; then
        return 0
    fi

    if [ "$MODE" != "force-init" ]; then
        log 'WARN: xray binary missing; rerun with --force-init to install xray-core'
        return 1
    fi

    log 'installing xray-core'
    pkg_install ca-bundle xray-core >/dev/null || die 'failed to install xray-core'
    command -v xray >/dev/null 2>&1 || die 'xray command not found after installing xray-core'
    mkdir -p /usr/local/xray
    ln -sf "$(command -v xray)" /usr/local/xray/xray
    [ -x /usr/local/xray/xray ] || die 'failed to link installed xray into /usr/local/xray/xray'
}

install_preroute_dependencies_if_needed() {
    pkg_init
    ensure_downloader_if_needed
    warn_or_install_command nft nftables 'nftables userspace tool'
    warn_or_install_command ip ip-full 'iproute2 routing control tool'
    warn_or_install_command uci uci 'OpenWrt UCI CLI'
    ensure_xray_binary
}

install_postroute_dependencies_if_needed() {
    pkg_init
    ensure_dnsmasq_full
}

warn_if_dependencies_missing() {
    command -v nft >/dev/null 2>&1 || log 'WARN: nft missing; rerun with --force-init to install nftables'
    command -v ip  >/dev/null 2>&1 || log 'WARN: ip missing; rerun with --force-init to install ip-full'
    command -v uci >/dev/null 2>&1 || log 'WARN: uci missing; rerun with --force-init to install uci'
    command -v nslookup >/dev/null 2>&1 || log 'WARN: nslookup missing; expected from base system'
    xray_binary_present || log 'WARN: xray binary missing; rerun with --force-init to install xray-core'
    pkg_init
    ensure_dnsmasq_full || true
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
            [ "$REPO_RAW_OVERRIDDEN" = 0 ] || {
                usage
                exit 2
            }
            REPO_RAW=$1
            REPO_RAW_OVERRIDDEN=1
            ;;
    esac
    shift
done

REPO_RAW=$(normalize_repo_raw "$REPO_RAW")

# ------- 1. preflight checks ---------------------------------------------

need_bin() {
    command -v "$1" >/dev/null 2>&1 || die "required binary not found: $1"
}

log 'checking required binaries'
log "using REPO_RAW=$REPO_RAW"
need_bin sh
need_bin awk
need_bin sed
need_bin grep
need_bin sort
need_bin uniq
need_bin nslookup
ensure_downloader_if_needed

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

# ------- 9. optional interactive secret setup ----------------------------

prompt_vless_urls_if_needed

# ------- 10. done ---------------------------------------------------------

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
        if critical_preroute_ready; then
            log 'critical pre-route dependencies already present; deferring OpenWrt package feeds until after routing'
        else
            log 'critical pre-route dependencies are missing; reaching package feeds is unavoidable before routing'
            install_preroute_dependencies_if_needed
        fi
        log 'running full initialization chain'
        "$XRAY_ROOT/bin/update-all.sh" || die 'update-all failed'
        /etc/init.d/xray enable >/dev/null 2>&1 || log 'WARN: failed to enable xray service'
        if ! /etc/init.d/xray status >/dev/null 2>&1; then
            /etc/init.d/xray start >/dev/null 2>&1 || die 'xray start failed after force-init'
        fi
        log 'installing/verifying post-route dependencies'
        install_postroute_dependencies_if_needed
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
warn_if_dependencies_missing
if [ "$secret_ready" -eq 1 ]; then
    log 'secret.env already looks complete; rerun with --force-init if you want bootstrap to render/apply/start automatically'
else
    log 'Next steps:'
    log '  1. cp /etc/xray/secret.env.example /etc/xray/secret.env'
    log '  2. vi /etc/xray/secret.env   # fill GEOSITE/GEOIP URLs and either T_VLESS_URL/A_VLESS_URL or split T_*/A_* vars'
    log '  3. chmod 600 /etc/xray/secret.env'
    log '  4. rerun bootstrap with --force-init'
fi
