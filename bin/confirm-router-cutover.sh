#!/bin/sh
set -eu

touch /tmp/sing-box-router-cutover-ok
if [ -f /tmp/sing-box-router-rollback.pid ]; then
    kill "$(cat /tmp/sing-box-router-rollback.pid)" 2>/dev/null || true
fi

if [ -x /etc/init.d/xray ]; then
    /etc/init.d/xray disable || true
fi

if [ -x /etc/init.d/sing-box-router ]; then
    /etc/init.d/sing-box-router enable || true
fi

if [ -x /etc/init.d/trusttunnel-client ]; then
    /etc/init.d/trusttunnel-client enable || true
fi

if [ -x /etc/init.d/router-clock-bootstrap ]; then
    /etc/init.d/router-clock-bootstrap enable || true
fi

echo "sing-box router cutover confirmed"
