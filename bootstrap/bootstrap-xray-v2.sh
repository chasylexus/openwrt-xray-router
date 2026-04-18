#!/bin/sh
# bootstrap-xray-v2.sh
#
# Устанавливает структуру /etc/xray, скачивает helper-скрипты, кладёт init.d/xray.
# НЕ стартует Xray — только подготовка. Первый старт — вручную после заполнения secret.env.
#
# Usage:
#   sh bootstrap-xray-v2.sh <REPO_RAW_URL>
#
# REPO_RAW_URL — базовый URL до raw-файлов репозитория, например:
#   https://raw.githubusercontent.com/you/openwrt-xray-router/main
#
# Идемпотентен: повторный запуск перезаписывает helpers и init.d/xray, но не трогает secret.env и lists/local.

set -eu

REPO_RAW="${1:-}"
if [ -z "$REPO_RAW" ]; then
    echo "usage: $0 <REPO_RAW_URL>" >&2
    exit 2
fi

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
apply-iprules.sh
apply-nft.sh
run-xray.sh
merge-lists.sh
update-sets.sh
update-assets.sh
update-managed-stack.sh
fetch-remote-lists.sh
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

log ''
log 'bootstrap OK'
log ''
log 'Next steps:'
log '  1. cp /etc/xray/secret.env.example /etc/xray/secret.env'
log '  2. vi /etc/xray/secret.env   # fill REPO_RAW (already pinned), LISTS_*_URL, T_* and A_*'
log '  3. chmod 600 /etc/xray/secret.env'
log '  4. /etc/xray/bin/update-managed-stack.sh'
log '  5. /etc/xray/bin/fetch-remote-lists.sh   # optional, if you configured remote lists'
log '  6. /etc/xray/bin/update-sets.sh'
log '  7. /etc/init.d/xray enable && /etc/init.d/xray start'
