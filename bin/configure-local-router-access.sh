#!/bin/sh
set -eu

# Local OpenWrt hardening for the common nested-router setup:
# WAN is connected to an upstream private router, LAN serves local clients.
# This script stores no credentials and only opens SSH from explicit RFC1918 CIDRs.

UPSTREAM_SSH_CIDR="${UPSTREAM_SSH_CIDR:-}"
LAN_SSH_CIDR="${LAN_SSH_CIDR:-}"
LAN_BRIDGE="${LAN_BRIDGE:-br-lan}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/router-stack-backups}"

log() { printf '[router-access] %s\n' "$*"; }
die() { printf '[router-access][FATAL] %s\n' "$*" >&2; exit 1; }
service_status() {
    set +e
    "/etc/init.d/$1" status >/dev/null 2>&1
    rc="$?"
    set -e
    printf '%s' "$rc"
}

[ "$(id -u)" = "0" ] || die "run as root on the router"
command -v uci >/dev/null 2>&1 || die "missing uci"
[ -n "$UPSTREAM_SSH_CIDR" ] || die "set UPSTREAM_SSH_CIDR explicitly"
[ -n "$LAN_SSH_CIDR" ] || die "set LAN_SSH_CIDR explicitly"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/local-access-$TS"
mkdir -p "$BACKUP_DIR/etc/config"

for cfg in firewall dropbear network; do
    [ -f "/etc/config/$cfg" ] && cp "/etc/config/$cfg" "$BACKUP_DIR/etc/config/$cfg"
done

delete_rule_by_name() {
    name="$1"
    while :; do
        found=""
        for section in $(uci show firewall 2>/dev/null | sed -n 's/^\(firewall\.[^=]*\)=rule$/\1/p'); do
            [ "$(uci -q get "$section.name" || true)" = "$name" ] || continue
            found="$section"
            break
        done
        [ -n "$found" ] || break
        uci delete "$found"
    done
}

add_ssh_rule() {
    name="$1"
    src="$2"
    cidr="$3"

    rule="$(uci add firewall rule)"
    uci set "firewall.$rule.name=$name"
    uci set "firewall.$rule.family=ipv4"
    uci set "firewall.$rule.src=$src"
    uci set "firewall.$rule.src_ip=$cidr"
    uci set "firewall.$rule.proto=tcp"
    uci set "firewall.$rule.dest_port=22"
    uci set "firewall.$rule.target=ACCEPT"
}

delete_rule_by_name 'TEMP_allow_SSH_from_upstream_laptop'
delete_rule_by_name 'Allow-SSH-from-upstream-private-net'
delete_rule_by_name 'Allow-SSH-from-LAN-private-net'
add_ssh_rule 'Allow-SSH-from-upstream-private-net' wan "$UPSTREAM_SSH_CIDR"
add_ssh_rule 'Allow-SSH-from-LAN-private-net' lan "$LAN_SSH_CIDR"
uci commit firewall
/etc/init.d/firewall reload

dropbear_section="$(uci show dropbear 2>/dev/null | sed -n 's/^\(dropbear\.[^=]*\)=dropbear$/\1/p' | head -n 1)"
if [ -z "$dropbear_section" ]; then
    dropbear_section="dropbear.$(uci add dropbear dropbear)"
fi
uci set "$dropbear_section.Port=22"
uci -q delete "$dropbear_section.Interface" || true
uci commit dropbear
/etc/init.d/dropbear restart || true

bridge_section=""
for section in $(uci show network 2>/dev/null | sed -n 's/^\(network\.[^=]*\)=device$/\1/p'); do
    [ "$(uci -q get "$section.name" || true)" = "$LAN_BRIDGE" ] || continue
    bridge_section="$section"
    break
done

[ -n "$bridge_section" ] || die "could not find network device for $LAN_BRIDGE"
uci set "$bridge_section.stp=1"
uci commit network

if [ -w "/sys/class/net/$LAN_BRIDGE/bridge/stp_state" ]; then
    echo 1 >"/sys/class/net/$LAN_BRIDGE/bridge/stp_state" || true
fi

log "backup: $BACKUP_DIR"
log "upstream SSH CIDR: $UPSTREAM_SSH_CIDR"
log "LAN SSH CIDR: $LAN_SSH_CIDR"
log "bridge STP: $(cat "/sys/class/net/$LAN_BRIDGE/bridge/stp_state" 2>/dev/null || true)"
log "dropbear: $(service_status dropbear)"
log "firewall: $(service_status firewall)"
