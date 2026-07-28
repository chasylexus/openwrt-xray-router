#!/bin/sh
# Transactionally refresh sing-box remote rule-sets without losing fake-IP state.

set -eu

SB_ROOT="/etc/sing-box-router"
SB_CONFIG="$SB_ROOT/config.json"
SB_DATA="/var/lib/sing-box-router"
SB_CACHE="$SB_DATA/cache.db"
SB_BIN="/usr/local/bin/sing-box"
SB_INIT="/etc/init.d/sing-box-router"
DNS_INIT="/etc/init.d/dnsmasq"
BACKUP_ROOT="/root/router-stack-backups"
LOCK_DIR="/tmp/sing-box-rule-refresh.lock"
REFRESH_TIMEOUT="${REFRESH_TIMEOUT:-600}"
RULE_REFRESH_TIMEOUT="${RULE_REFRESH_TIMEOUT:-30}"

log() { printf '[rule-refresh] %s\n' "$*"; }
die() { printf '[rule-refresh][FATAL] %s\n' "$*" >&2; exit 1; }

wait_local_port() {
    port="$1"
    timeout="${2:-30}"
    i=0

    while [ "$i" -lt "$timeout" ]; do
        if { ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null || true; } |
            grep -q "127.0.0.1:$port"; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done

    return 1
}

extract_remote_rule_tags() {
    awk '
        /"tag"[ \t]*:/ {
            value = $0
            sub(/^.*"tag"[ \t]*:[ \t]*"/, "", value)
            sub(/".*$/, "", value)
            tag = value
        }
        /"url"[ \t]*:/ && tag != "" {
            print tag
            tag = ""
        }
    ' "$1" | sort -u
}

rule_update_succeeded() {
    tag="$1"
    refresh_log="$2"
    grep -Fq "updated rule-set $tag" "$refresh_log" ||
        grep -Fq "update rule-set $tag: not modified" "$refresh_log"
}

make_refresh_config() {
    target_tag="$1"
    destination="$2"

    awk -v target="$target_tag" '
        /"tag"[ \t]*:/ {
            value = $0
            sub(/^.*"tag"[ \t]*:[ \t]*"/, "", value)
            sub(/".*$/, "", value)
            tag = value
        }
        /"update_interval"[ \t]*:/ {
            if (tag == target) {
                sub(/"update_interval"[ \t]*:[ \t]*"[^"]*"/,
                    "\"update_interval\": \"1s\"")
            } else {
                sub(/"update_interval"[ \t]*:[ \t]*"[^"]*"/,
                    "\"update_interval\": \"87600h\"")
            }
        }
        {
            if ($0 ~ /"level"[ \t]*:[ \t]*"warn"/) {
                sub(/"level"[ \t]*:[ \t]*"warn"/, "\"level\": \"info\"")
            }
            print
        }
    ' "$NORMAL_CONFIG" > "$destination"
}

stop_refresh_process() {
    if [ -r "${REFRESH_CHILD_PID_FILE:-}" ]; then
        child_pid="$(cat "$REFRESH_CHILD_PID_FILE" 2>/dev/null || true)"
        [ -z "$child_pid" ] || kill "$child_pid" 2>/dev/null || true
    fi
    [ -n "${REFRESH_PID:-}" ] || return 0
    kill "$REFRESH_PID" 2>/dev/null || true
    wait "$REFRESH_PID" 2>/dev/null || true
    REFRESH_PID=""
    rm -f "${REFRESH_CHILD_PID_FILE:-}"
}

run_bounded_refresh() {
    hard_timeout=$((RULE_REFRESH_TIMEOUT + 15))
    child_pid=""
    timer_pid=""

    cleanup_supervisor() {
        trap - EXIT HUP INT TERM
        [ -z "$timer_pid" ] || kill "$timer_pid" 2>/dev/null || true
        [ -z "$child_pid" ] || kill "$child_pid" 2>/dev/null || true
        [ -z "$child_pid" ] || wait "$child_pid" 2>/dev/null || true
        rm -f "$REFRESH_CHILD_PID_FILE"
    }

    trap cleanup_supervisor EXIT HUP INT TERM
    "$SB_BIN" -D "$SB_DATA" -C "$STAGE_ROOT" run \
        >"$REFRESH_LOG" 2>&1 &
    child_pid="$!"
    printf '%s\n' "$child_pid" > "$REFRESH_CHILD_PID_FILE"
    (
        sleep "$hard_timeout"
        kill "$child_pid" 2>/dev/null || true
    ) &
    timer_pid="$!"
    wait "$child_pid"
}

emergency_cleanup() {
    rc="$?"
    trap - EXIT HUP INT TERM

    if [ "${MAINTENANCE_ACTIVE:-0}" = "1" ]; then
        set +e
        stop_refresh_process
        "$SB_INIT" stop >/dev/null 2>&1

        if [ "${REFRESH_COMMITTED:-0}" != "1" ] &&
            [ "${CACHE_SNAPSHOT_READY:-0}" = "1" ] &&
            [ -f "$CACHE_BACKUP" ]; then
            if [ -f "$SB_CACHE" ]; then
                mv "$SB_CACHE" "$BACKUP_DIR/cache.db.failed-refresh"
            fi
            cp -a "$CACHE_BACKUP" "$SB_CACHE"
        fi

        "$SB_INIT" start >/dev/null 2>&1
        wait_local_port 1053 45
        wait_local_port 10809 45
        "$DNS_INIT" restart >/dev/null 2>&1
        [ "$rc" -eq 0 ] || log "rollback completed from $BACKUP_DIR"
    fi

    rmdir "$LOCK_DIR" 2>/dev/null || true
    exit "$rc"
}

restore_managed_stack() {
    "$SB_INIT" start >/dev/null 2>&1 || return 1
    wait_local_port 1053 45 || return 1
    wait_local_port 10809 45 || return 1
    "$DNS_INIT" restart >/dev/null 2>&1 || return 1
}

rollback_refresh() {
    reason="$1"
    die "$reason; automatic rollback will use $BACKUP_DIR"
}

[ "$(id -u)" = "0" ] || die "run as root on the router"
[ -x "$SB_BIN" ] || die "sing-box binary missing: $SB_BIN"
[ -x "$SB_INIT" ] || die "sing-box init script missing: $SB_INIT"
[ -x "$DNS_INIT" ] || die "dnsmasq init script missing: $DNS_INIT"
[ -r "$SB_CONFIG" ] || die "sing-box config missing: $SB_CONFIG"
[ "$REFRESH_TIMEOUT" -ge 60 ] 2>/dev/null ||
    die "REFRESH_TIMEOUT must be an integer of at least 60 seconds"
[ "$RULE_REFRESH_TIMEOUT" -ge 10 ] 2>/dev/null ||
    die "RULE_REFRESH_TIMEOUT must be an integer of at least 10 seconds"
if grep -Fq '"update_interval": "1s"' "$SB_CONFIG"; then
    die "active config already contains a one-second rule interval; restore or re-render it before refreshing"
fi

mkdir "$LOCK_DIR" 2>/dev/null ||
    die "another rule refresh is already running: $LOCK_DIR"
MAINTENANCE_ACTIVE=0
CACHE_SNAPSHOT_READY=0
REFRESH_COMMITTED=0
REFRESH_PID=""
trap emergency_cleanup EXIT
trap 'exit 130' HUP INT TERM

wait_local_port 11080 2 ||
    die "TrustTunnel SOCKS listener is not ready on 127.0.0.1:11080"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$TS-rule-refresh"
NORMAL_CONFIG="$BACKUP_DIR/config.json.normal"
STAGE_ROOT="$BACKUP_DIR/stage-config"
REFRESH_CONFIG="$STAGE_ROOT/config.json"
CACHE_BACKUP="$BACKUP_DIR/cache.db.before-refresh"
RULE_TAGS="$BACKUP_DIR/remote-rule-tags.txt"
REFRESH_CHILD_PID_FILE="$BACKUP_DIR/refresh.pid"
mkdir -p "$STAGE_ROOT"

cp "$SB_CONFIG" "$NORMAL_CONFIG"
chmod 600 "$NORMAL_CONFIG"
extract_remote_rule_tags "$NORMAL_CONFIG" > "$RULE_TAGS"
EXPECTED_RULES="$(wc -l < "$RULE_TAGS" | tr -d ' ')"
[ "$EXPECTED_RULES" -gt 0 ] ||
    die "no remote rule-set tags found in $SB_CONFIG"

FIRST_TAG="$(head -n 1 "$RULE_TAGS")"
make_refresh_config "$FIRST_TAG" "$REFRESH_CONFIG"
chmod 600 "$REFRESH_CONFIG"

if ! "$SB_BIN" -D "$SB_DATA" -C "$STAGE_ROOT" check >"$BACKUP_DIR/check.log" 2>&1; then
    die "temporary refresh config failed validation; see $BACKUP_DIR/check.log"
fi

log "staging complete: $EXPECTED_RULES remote rule-sets, backup $BACKUP_DIR"
log "stopping managed sing-box for a consistent cache snapshot; dnsmasq stays up"
log "remote rule-sets will refresh sequentially to avoid a parallel TLS storm"
MAINTENANCE_ACTIVE=1
"$SB_INIT" stop >/dev/null 2>&1 || true

if [ -f "$SB_CACHE" ]; then
    cp -a "$SB_CACHE" "$CACHE_BACKUP"
fi
CACHE_SNAPSHOT_READY=1

UPDATED_RULES=0
OVERALL_DEADLINE=$(( $(date +%s) + REFRESH_TIMEOUT ))
while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    [ "$(date +%s)" -lt "$OVERALL_DEADLINE" ] ||
        rollback_refresh "overall refresh timeout after $UPDATED_RULES of $EXPECTED_RULES rule-sets"

    make_refresh_config "$tag" "$REFRESH_CONFIG"
    chmod 600 "$REFRESH_CONFIG"
    if ! "$SB_BIN" -D "$SB_DATA" -C "$STAGE_ROOT" check \
        >"$BACKUP_DIR/check-$tag.log" 2>&1; then
        rollback_refresh "temporary config check failed for $tag"
    fi

    REFRESH_LOG="$BACKUP_DIR/refresh-$tag.log"
    : > "$REFRESH_LOG"
    run_bounded_refresh &
    REFRESH_PID="$!"

    if ! wait_local_port 10809 20; then
        rollback_refresh "temporary sing-box did not open its test listener for $tag"
    fi

    i=0
    refreshed=0
    while [ "$i" -lt "$RULE_REFRESH_TIMEOUT" ] &&
        [ "$(date +%s)" -lt "$OVERALL_DEADLINE" ]; do
        if rule_update_succeeded "$tag" "$REFRESH_LOG"; then
            refreshed=1
            break
        fi
        if ! kill -0 "$REFRESH_PID" 2>/dev/null; then
            break
        fi
        i=$((i + 1))
        sleep 1
    done

    stop_refresh_process
    [ "$refreshed" = "1" ] ||
        rollback_refresh "rule-set $tag did not refresh within ${RULE_REFRESH_TIMEOUT}s"
    UPDATED_RULES=$((UPDATED_RULES + 1))
    log "refreshed $UPDATED_RULES/$EXPECTED_RULES: $tag"
done < "$RULE_TAGS"

if ! restore_managed_stack; then
    rollback_refresh "managed sing-box failed after successful rule refresh"
fi
REFRESH_COMMITTED=1
MAINTENANCE_ACTIVE=0

log "refresh complete: $UPDATED_RULES of $EXPECTED_RULES rule-sets"
log "active config was never replaced; fake-IP cache preserved"
log "dnsmasq stayed up and was restarted after the managed service health check"
log "backup retained at $BACKUP_DIR"
