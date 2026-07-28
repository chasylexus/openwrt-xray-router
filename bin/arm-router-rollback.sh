#!/bin/sh
set -eu

rm -f /tmp/sing-box-router-cutover-ok
nohup sh -c 'sleep 300; [ -f /tmp/sing-box-router-cutover-ok ] || /root/bin/rollback-to-legacy-xray.sh' >/tmp/sing-box-router-rollback-timer.log 2>&1 &
echo "$!" >/tmp/sing-box-router-rollback.pid
echo "rollback timer armed: pid $(cat /tmp/sing-box-router-rollback.pid)"
