#!/bin/sh

set -u

API_URL="http://127.0.0.1:9090/proxies/tailscale-underlay"
CHECK_URL="https://www.gstatic.com/generate_204"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
RECOVER_THRESHOLD="${RECOVER_THRESHOLD:-2}"
CHECK_INTERVAL="${CHECK_INTERVAL:-20}"
STATE_FILE="/tmp/tailscale-underlay-selector.json"

get_selected() {
    curl -fsS --max-time 3 "$API_URL" -o "$STATE_FILE" 2>/dev/null || return 1
    jsonfilter -i "$STATE_FILE" -e '@.now' 2>/dev/null
}

select_outbound() {
    target="$1"
    printf '%s' "{\"name\":\"$target\"}" |
        curl -fsS --max-time 3 \
            -X PUT \
            -H 'Content-Type: application/json' \
            --data-binary @- \
            "$API_URL" >/dev/null
}

trusttunnel_healthy() {
    curl -4 -fsS --max-time 12 \
        --socks5-hostname 127.0.0.1:11080 \
        -o /dev/null \
        "$CHECK_URL"
}

failures=0
successes=0

while :; do
    selected="$(get_selected 2>/dev/null || true)"

    if trusttunnel_healthy; then
        failures=0
        successes=$((successes + 1))
        if [ "$successes" -ge "$RECOVER_THRESHOLD" ] && [ "$selected" != "tt-t" ]; then
            if select_outbound tt-t; then
                logger -t tailscale-underlay "selected tt-t after $successes successful checks"
                successes=0
            fi
        fi
    else
        successes=0
        failures=$((failures + 1))
        if [ "$failures" -ge "$FAIL_THRESHOLD" ] && [ "$selected" != "direct" ]; then
            if select_outbound direct; then
                logger -t tailscale-underlay "selected direct after $failures failed checks"
                failures=0
            fi
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
