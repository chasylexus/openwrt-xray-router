#!/bin/sh
# Bootstrap the neutral TrustTunnel + sing-box router stack on OpenWrt/apk.
# Real TrustTunnel credentials are never stored in this repository.

set -eu

MODE="ensure"
DEFAULT_REPO_RAW=""
REPO_RAW="$DEFAULT_REPO_RAW"

SB_ROOT="/etc/sing-box-router"
TT_ROOT="/etc/trusttunnel"
TT_CONF="$TT_ROOT/router-client.toml"
TT_BIN="/opt/trusttunnel/trusttunnel_client"
BACKUP_ROOT="/root/router-stack-backups"

SING_BOX_VERSION="${SING_BOX_VERSION:-1.13.11}"
SING_BOX_SHA256="${SING_BOX_SHA256:-}"
SING_BOX_URL="${SING_BOX_URL:-}"
TT_CLIENT_URL="${TT_CLIENT_URL:-}"
TT_ENDPOINT_IPV4="${TT_ENDPOINT_IPV4:-}"
UPSTREAM_DNS="${UPSTREAM_DNS:-}"
WAN_INTERFACE="${WAN_INTERFACE:-}"
RULESET_BASE="${RULESET_BASE:-}"
SYSUPGRADE_CONF="${SYSUPGRADE_CONF:-/etc/sysupgrade.conf}"

log() { printf '[router-bootstrap] %s\n' "$*"; }
warn() { printf '[router-bootstrap][WARN] %s\n' "$*" >&2; }
die() { printf '[router-bootstrap][FATAL] %s\n' "$*" >&2; exit 1; }

usage() {
    cat >&2 <<'EOF'
usage:
  sh bootstrap-sing-box-router.sh [--ensure|--apply|--refresh-rules] [options]

options:
  --repo-raw URL          raw GitHub base URL for repo-tracked files
  --tt-endpoint-ip IPv4   TrustTunnel endpoint IPv4 for sing-box anti-loop exclude
  --upstream-dns IP       direct DNS server for non-proxied lookups
  --wan-interface IFACE   physical WAN interface used by direct outbound
  --ruleset-base URL      base URL containing the manual sing-box rule sets

environment overrides:
  REPO_RAW, TT_ENDPOINT_IPV4, UPSTREAM_DNS, WAN_INTERFACE, RULESET_BASE
  TT_CLIENT_URL           optional URL to download the TrustTunnel client binary
  SING_BOX_URL            optional URL to download a sing-box archive
  SING_BOX_SHA256         sha256 for SING_BOX_URL, or empty to skip verification

Default mode is --ensure: install files and templates, but do not cut over.
Use --apply after /etc/trusttunnel/router-client.toml is filled locally.
Use --refresh-rules for a forced transactional remote rule-set refresh that
preserves the sing-box fake-IP cache.
EOF
}

normalize_repo_raw() {
    printf '%s' "$1" | sed 's#^[[:space:]]*##; s#[[:space:]]*$##; s#/*$##'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ensure)
            MODE="ensure"
            shift
            ;;
        --apply|--force-init)
            MODE="apply"
            shift
            ;;
        --refresh-rules)
            MODE="refresh-rules"
            shift
            ;;
        --repo-raw)
            [ "$#" -ge 2 ] || die "--repo-raw needs a value"
            REPO_RAW="$2"
            shift 2
            ;;
        --tt-endpoint-ip)
            [ "$#" -ge 2 ] || die "--tt-endpoint-ip needs a value"
            TT_ENDPOINT_IPV4="$2"
            shift 2
            ;;
        --upstream-dns)
            [ "$#" -ge 2 ] || die "--upstream-dns needs a value"
            UPSTREAM_DNS="$2"
            shift 2
            ;;
        --wan-interface)
            [ "$#" -ge 2 ] || die "--wan-interface needs a value"
            WAN_INTERFACE="$2"
            shift 2
            ;;
        --ruleset-base)
            [ "$#" -ge 2 ] || die "--ruleset-base needs a value"
            RULESET_BASE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        http://*|https://*)
            REPO_RAW="$1"
            shift
            ;;
        *)
            usage
            die "unknown argument: $1"
            ;;
    esac
done

[ -n "${REPO_RAW:-}" ] || die "set REPO_RAW or pass --repo-raw"
REPO_RAW="$(normalize_repo_raw "$REPO_RAW")"
[ -z "$RULESET_BASE" ] || RULESET_BASE="$(normalize_repo_raw "$RULESET_BASE")"

[ "$(id -u)" = "0" ] || die "run as root on the router"
command -v apk >/dev/null 2>&1 || die "this bootstrap targets OpenWrt builds with apk"

if command -v curl >/dev/null 2>&1; then
    FETCH="curl -4 -fsSL -o"
elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -4 -q -O"
elif command -v uclient-fetch >/dev/null 2>&1; then
    FETCH="uclient-fetch -4 -O"
else
    FETCH=""
fi

fetch() {
    fetch_url="$1"
    fetch_dest="$2"
    [ -n "$FETCH" ] || die "no downloader found; install curl or wget"
    # shellcheck disable=SC2086
    $FETCH "$fetch_dest" "$fetch_url"
}

apk_add_best_effort() {
    apk update >/dev/null 2>&1 || true
    for pkg in "$@"; do
        apk info -e "$pkg" >/dev/null 2>&1 && continue
        apk add "$pkg" >/dev/null 2>&1 || warn "could not install package: $pkg"
    done
}

install_repo_file() {
    install_rel="$1"
    install_dest="$2"
    install_mode="$3"
    install_tmp="/tmp/router-bootstrap.$$.tmp"
    fetch "$REPO_RAW/$install_rel" "$install_tmp"
    mkdir -p "$(dirname "$install_dest")"
    cp "$install_tmp" "$install_dest"
    chmod "$install_mode" "$install_dest"
    rm -f "$install_tmp"
}

backup_path() {
    path="$1"
    [ -e "$path" ] || return 0
    rel="${path#/}"
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    cp -a "$path" "$BACKUP_DIR/$rel"
}

detect_wan_interface() {
    ip -4 route show default 2>/dev/null | awk '/default/ { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

detect_upstream_dns() {
    value=""
    for f in /tmp/resolv.conf.d/resolv.conf.auto /tmp/resolv.conf.auto /etc/resolv.conf; do
        [ -r "$f" ] || continue
        value="$(awk '/^nameserver[ \t]+[0-9.]+/ { print $2; exit }' "$f")"
        [ -n "$value" ] || continue
        [ "$value" = "127.0.0.1" ] && continue
        printf '%s\n' "$value"
        return 0
    done
    ip -4 route show default 2>/dev/null | awk '/default/ { print $3; exit }'
}

extract_tt_endpoint_ipv4() {
    [ -r "$TT_CONF" ] || return 0
    awk '
        /^\[endpoint\][[:space:]]*$/ {
            in_endpoint = 1
            next
        }
        /^\[/ {
            in_endpoint = 0
        }
        in_endpoint && /^[[:space:]]*addresses[[:space:]]*=/ {
            line = $0
            while (match(line, /[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/)) {
                candidate = substr(line, RSTART, RLENGTH)
                count = split(candidate, octet, ".")
                valid = count == 4
                for (i = 1; i <= 4; i++) {
                    if (octet[i] !~ /^[0-9]+$/ || octet[i] > 255) {
                        valid = 0
                    }
                }
                if (valid) {
                    print candidate
                    exit
                }
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$TT_CONF"
}

prompt_if_tty() {
    prompt="$1"
    default="$2"
    [ -t 0 ] && [ -t 1 ] || {
        printf '%s\n' "$default"
        return 0
    }
    if [ -n "$default" ]; then
        printf '%s [%s]: ' "$prompt" "$default" >/dev/tty
    else
        printf '%s: ' "$prompt" >/dev/tty
    fi
    IFS= read -r value </dev/tty || value=""
    [ -n "$value" ] || value="$default"
    printf '%s\n' "$value"
}

sed_escape() {
    printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

ensure_sing_box() {
    current_bin=""
    if [ -x /usr/local/bin/sing-box ]; then
        current_bin="/usr/local/bin/sing-box"
    elif command -v sing-box >/dev/null 2>&1; then
        current_bin="$(command -v sing-box)"
    fi

    current_version=""
    if [ -n "$current_bin" ]; then
        current_version="$("$current_bin" version 2>/dev/null | awk '/^sing-box version / { print $3; exit }')"
    fi
    if [ "$current_version" = "$SING_BOX_VERSION" ]; then
        if [ "$current_bin" != "/usr/local/bin/sing-box" ]; then
            mkdir -p /usr/local/bin
            ln -sf "$current_bin" /usr/local/bin/sing-box
        fi
        return 0
    fi

    if [ -n "$current_version" ]; then
        log "replacing sing-box $current_version with pinned $SING_BOX_VERSION"
    fi

    case "$(uname -m)" in
        aarch64|arm64)
            asset="sing-box-$SING_BOX_VERSION-linux-arm64-musl.tar.gz"
            ;;
        *)
            die "automatic sing-box archive install is only pinned for arm64; set SING_BOX_URL manually"
            ;;
    esac

    if [ -z "$SING_BOX_URL" ]; then
        SING_BOX_URL="https://github.com/SagerNet/sing-box/releases/download/v$SING_BOX_VERSION/$asset"
        if [ -z "$SING_BOX_SHA256" ] && [ "$SING_BOX_VERSION" = "1.13.11" ]; then
            SING_BOX_SHA256="da8380fc3387a0a431cda259acd90098d988d7e679c780f0ecef3ced7534216c"
        fi
    fi

    tmpdir="/tmp/sing-box-install.$$"
    archive="$tmpdir/$asset"
    mkdir -p "$tmpdir"
    log "downloading sing-box $SING_BOX_VERSION"
    fetch "$SING_BOX_URL" "$archive"
    if [ -n "$SING_BOX_SHA256" ] && command -v sha256sum >/dev/null 2>&1; then
        printf '%s  %s\n' "$SING_BOX_SHA256" "$archive" | sha256sum -c - >/dev/null
    fi
    tar -xzf "$archive" -C "$tmpdir"
    found=""
    for p in "$tmpdir"/*/sing-box "$tmpdir"/sing-box; do
        [ -x "$p" ] || continue
        found="$p"
        break
    done
    [ -n "$found" ] || die "sing-box binary not found in downloaded archive"
    mkdir -p /usr/local/bin
    cp "$found" "$tmpdir/sing-box.new"
    chmod 755 "$tmpdir/sing-box.new"
    mv "$tmpdir/sing-box.new" /usr/local/bin/sing-box
    rm -rf "$tmpdir"
}

ensure_sysupgrade_path() {
    preserve_path="$1"
    mkdir -p "$(dirname "$SYSUPGRADE_CONF")"
    touch "$SYSUPGRADE_CONF"
    grep -Fqx "$preserve_path" "$SYSUPGRADE_CONF" 2>/dev/null ||
        printf '%s\n' "$preserve_path" >>"$SYSUPGRADE_CONF"
}

ensure_trusttunnel_binary() {
    if [ -x "$TT_BIN" ]; then
        return 0
    fi
    [ -n "$TT_CLIENT_URL" ] || return 1
    mkdir -p "$(dirname "$TT_BIN")"
    log "downloading TrustTunnel client binary"
    fetch "$TT_CLIENT_URL" "$TT_BIN"
    chmod 700 "$TT_BIN"
}

render_sing_box_config() {
    dns_value="${UPSTREAM_DNS:-$(detect_upstream_dns)}"
    wan_value="${WAN_INTERFACE:-$(detect_wan_interface)}"
    tt_value="${TT_ENDPOINT_IPV4:-$(extract_tt_endpoint_ipv4)}"
    rules_value="${RULESET_BASE:-}"

    [ -n "$dns_value" ] || dns_value="1.1.1.1"
    [ -n "$wan_value" ] || wan_value="eth0"

    if [ -z "$tt_value" ]; then
        tt_value="$(prompt_if_tty 'TrustTunnel endpoint IPv4 for route exclude' '')"
    fi
    if [ -z "$rules_value" ]; then
        rules_value="$(prompt_if_tty 'Base URL for manual sing-box rule sets' '')"
    fi

    tmp="$SB_ROOT/config.json.new.$$"
    sed \
        -e "s#__UPSTREAM_DNS__#$(sed_escape "$dns_value")#g" \
        -e "s#__WAN_INTERFACE__#$(sed_escape "$wan_value")#g" \
        -e "s#__TT_ENDPOINT_IPV4__#$(sed_escape "${tt_value:-REPLACE_WITH_TT_ENDPOINT_IPV4}")#g" \
        -e "s#__RULESET_BASE__#$(sed_escape "${rules_value:-REPLACE_WITH_RULESET_BASE}")#g" \
        "$SB_ROOT/config.json.tpl" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$SB_ROOT/config.json"
}

trusttunnel_config_ready() {
    [ -r "$TT_CONF" ] || return 1
    ! grep -q 'REPLACE_WITH_' "$TT_CONF"
}

sing_box_config_ready() {
    [ -r "$SB_ROOT/config.json" ] || return 1
    ! grep -q 'REPLACE_WITH_' "$SB_ROOT/config.json"
}

configure_firewall() {
    uci set firewall.singbox_tun='zone'
    uci set firewall.singbox_tun.name='singbox_tun'
    uci set firewall.singbox_tun.input='REJECT'
    uci set firewall.singbox_tun.output='ACCEPT'
    uci set firewall.singbox_tun.forward='ACCEPT'
    uci -q delete firewall.singbox_tun.device || true
    uci add_list firewall.singbox_tun.device='sb-tun0'

    uci set firewall.lan_to_singbox_tun='forwarding'
    uci set firewall.lan_to_singbox_tun.src='lan'
    uci set firewall.lan_to_singbox_tun.dest='singbox_tun'
    uci commit firewall
    /etc/init.d/firewall reload
}

configure_dnsmasq() {
    uci -q delete dhcp.@dnsmasq[0].server || true
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#1053'
    uci set dhcp.lan.dhcpv6='disabled'
    uci set dhcp.lan.ra='disabled'
    uci set dhcp.lan.ndp='disabled'
    uci commit dhcp
    /etc/init.d/dnsmasq restart
}

configure_tailscale_underlay() {
    [ -x /usr/sbin/tailscaled ] || {
        warn "tailscaled is not installed; skipping the Tailscale underlay"
        return 0
    }

    uci -q get tailscale.settings >/dev/null 2>&1 ||
        uci set tailscale.settings='settings'
    uci set tailscale.settings.http_proxy='http://127.0.0.1:10810'
    uci set tailscale.settings.https_proxy='http://127.0.0.1:10810'
    uci set tailscale.settings.no_proxy='127.0.0.1,localhost,::1'
    uci set tailscale.settings.always_use_derp='1'
    uci commit tailscale

    /etc/init.d/tailscale enable
    /etc/init.d/tailscale-underlay-watchdog enable
    /etc/init.d/tailscale-underlay-watchdog restart
}

disable_legacy_stack() {
    if [ -x /etc/init.d/xray ]; then
        /etc/init.d/xray stop || true
        /etc/init.d/xray disable || true
    fi
    if [ -x /etc/init.d/sing-box-passive ]; then
        /etc/init.d/sing-box-passive stop || true
        /etc/init.d/sing-box-passive disable || true
    fi
}

wait_local_port() {
    port="$1"
    timeout="${2:-30}"
    i=0

    while [ "$i" -lt "$timeout" ]; do
        if { ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null || true; } | grep -q "127.0.0.1:$port"; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done

    return 1
}

apply_stack() {
    ensure_trusttunnel_binary || die "TrustTunnel binary missing; place it at $TT_BIN or set TT_CLIENT_URL"
    trusttunnel_config_ready || die "fill placeholders in $TT_CONF first"
    sing_box_config_ready || die "rendered sing-box config still has placeholders; set --tt-endpoint-ip"

    /usr/local/bin/sing-box -D /var/lib/sing-box-router -C "$SB_ROOT" check

    log "configuring firewall before traffic cutover"
    configure_firewall

    log "starting TrustTunnel client"
    /etc/init.d/trusttunnel-client enable
    /etc/init.d/router-clock-bootstrap enable
    /etc/init.d/router-clock-bootstrap start
    /etc/init.d/trusttunnel-client restart
    /etc/init.d/trusttunnel-client status >/dev/null
    wait_local_port 11080 45 || die "TrustTunnel SOCKS listener did not become ready on 127.0.0.1:11080"

    log "stopping legacy stack and starting sing-box router"
    [ -x /root/bin/arm-router-rollback.sh ] && /root/bin/arm-router-rollback.sh || true
    disable_legacy_stack
    /etc/init.d/sing-box-router enable
    /etc/init.d/sing-box-router restart
    /etc/init.d/sing-box-router status >/dev/null
    wait_local_port 1053 45 || die "sing-box DNS listener did not become ready on 127.0.0.1:1053"
    wait_local_port 10809 45 || die "sing-box test listener did not become ready on 127.0.0.1:10809"
    wait_local_port 10810 45 || die "Tailscale underlay proxy did not become ready on 127.0.0.1:10810"

    log "switching DNS to sing-box after service health check"
    configure_dnsmasq
    configure_tailscale_underlay
    [ -x /root/bin/confirm-router-cutover.sh ] && /root/bin/confirm-router-cutover.sh || true
}

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$TS"
mkdir -p "$BACKUP_DIR"

log "backing up mutable router files to $BACKUP_DIR"
backup_path /etc/config/dhcp
backup_path /etc/config/firewall
backup_path /etc/config/dropbear
backup_path /etc/config/network
backup_path "$SB_ROOT/config.json"
backup_path "$SB_ROOT/config.json.tpl"
backup_path "$TT_CONF"
backup_path /etc/init.d/sing-box-router
backup_path /etc/init.d/trusttunnel-client
backup_path /etc/init.d/router-clock-bootstrap
backup_path /etc/init.d/tailscale
backup_path /etc/init.d/tailscale-underlay-watchdog
backup_path /etc/init.d/xray

apk_add_best_effort ca-bundle curl kmod-tun nftables ip-full tailscale
[ -n "$FETCH" ] || {
    if command -v curl >/dev/null 2>&1; then
        FETCH="curl -4 -fsSL -o"
    elif command -v wget >/dev/null 2>&1; then
        FETCH="wget -4 -q -O"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        FETCH="uclient-fetch -4 -O"
    fi
}

command -v ip >/dev/null 2>&1 || die "missing ip command after package install"
command -v uci >/dev/null 2>&1 || die "missing uci command"

ensure_sing_box
ensure_sysupgrade_path /usr/local/bin/sing-box

install_repo_file sing-box-router/config.json.tpl "$SB_ROOT/config.json.tpl" 600
install_repo_file trusttunnel/router-client.toml.example "$TT_ROOT/router-client.toml.example" 600
install_repo_file init.d/sing-box-router /etc/init.d/sing-box-router 755
install_repo_file init.d/trusttunnel-client /etc/init.d/trusttunnel-client 755
install_repo_file init.d/router-clock-bootstrap /etc/init.d/router-clock-bootstrap 755
install_repo_file init.d/tailscale /etc/init.d/tailscale 755
install_repo_file init.d/tailscale-underlay-watchdog /etc/init.d/tailscale-underlay-watchdog 755
install_repo_file bin/rollback-to-legacy-xray.sh /root/bin/rollback-to-legacy-xray.sh 700
install_repo_file bin/arm-router-rollback.sh /root/bin/arm-router-rollback.sh 700
install_repo_file bin/confirm-router-cutover.sh /root/bin/confirm-router-cutover.sh 700
install_repo_file bin/configure-local-router-access.sh /root/bin/configure-local-router-access.sh 700
install_repo_file bin/refresh-sing-box-rules.sh /root/bin/refresh-sing-box-rules.sh 700
install_repo_file bin/tailscale-underlay-watchdog.sh /root/bin/tailscale-underlay-watchdog.sh 700
install_repo_file bootstrap/bootstrap-sing-box-router.sh /root/bin/bootstrap-sing-box-router.sh 700

mkdir -p "$TT_ROOT"
if [ ! -e "$TT_CONF" ]; then
    cp "$TT_ROOT/router-client.toml.example" "$TT_CONF"
    chmod 600 "$TT_CONF"
    log "created $TT_CONF with placeholders; fill it locally before --apply"
fi

render_sing_box_config

if sing_box_config_ready; then
    /usr/local/bin/sing-box -D /var/lib/sing-box-router -C "$SB_ROOT" check
else
    warn "sing-box config still has placeholders; rerun with --tt-endpoint-ip or fill the TT config"
fi

case "$MODE" in
    ensure)
        log "ensure complete; no traffic cutover performed"
        log "next: fill $TT_CONF locally, then rerun with --apply"
        ;;
    apply)
        apply_stack
        log "apply complete"
        ;;
    refresh-rules)
        trusttunnel_config_ready || die "fill placeholders in $TT_CONF first"
        sing_box_config_ready || die "rendered sing-box config still has placeholders"
        /root/bin/refresh-sing-box-rules.sh
        log "rule refresh complete"
        ;;
    *)
        die "internal mode error"
        ;;
esac
