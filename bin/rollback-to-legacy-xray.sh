#!/bin/sh
set -eu

LOG="/tmp/rollback-to-legacy-xray.log"
exec >>"$LOG" 2>&1

echo "[$(date -Iseconds)] rollback start"

if [ -x /etc/init.d/voidboost-egress-watchdog ]; then
    /etc/init.d/voidboost-egress-watchdog stop || true
    /etc/init.d/voidboost-egress-watchdog disable || true
fi

latest_backup() {
    ls -1dt /root/router-stack-backups/* 2>/dev/null | head -n 1
}

if [ -x /etc/init.d/sing-box-router ]; then
    /etc/init.d/sing-box-router stop || true
    /etc/init.d/sing-box-router disable || true
fi

if [ -x /etc/init.d/trusttunnel-client ]; then
    /etc/init.d/trusttunnel-client stop || true
    /etc/init.d/trusttunnel-client disable || true
fi

backup_dir="$(latest_backup || true)"

if [ -n "$backup_dir" ] && [ -f "$backup_dir/etc/config/dhcp" ]; then
    cp "$backup_dir/etc/config/dhcp" /etc/config/dhcp
elif [ -f /root/dhcp.before-sing-box-router ]; then
    cp /root/dhcp.before-sing-box-router /etc/config/dhcp
fi

if [ -n "$backup_dir" ] && [ -f "$backup_dir/etc/config/firewall" ]; then
    cp "$backup_dir/etc/config/firewall" /etc/config/firewall
fi

/etc/init.d/dnsmasq restart || true

if [ -x /etc/init.d/xray ]; then
    /etc/init.d/xray enable || true
    /etc/init.d/xray restart || true
fi

/etc/init.d/firewall reload || true

echo "[$(date -Iseconds)] rollback done"
