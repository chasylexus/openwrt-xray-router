#!/bin/sh
# load-env.sh
#
# Shared env loader for the router stack. Source repo.env + secret.env,
# normalize defaults, and optionally derive T_/A_ outbound settings from
# VLESS share links.

set -eu

XRAY_ROOT="${XRAY_ROOT:-/etc/xray}"

xray_env_die() {
    printf '[load-env][FATAL] %s\n' "$*" >&2
    return 1
}

xray_env_repo_file() {
    if [ -n "${XRAY_REPO_ENV_FILE:-}" ]; then
        printf '%s\n' "$XRAY_REPO_ENV_FILE"
    else
        printf '%s/repo.env\n' "$XRAY_ROOT"
    fi
}

xray_env_secret_file() {
    if [ -n "${XRAY_SECRET_ENV_FILE:-}" ]; then
        printf '%s\n' "$XRAY_SECRET_ENV_FILE"
    else
        printf '%s/secret.env\n' "$XRAY_ROOT"
    fi
}

xray_env_urldecode() {
    printf '%b' "$(printf '%s' "$1" | sed 's/%/\\x/g')"
}

xray_env_query_get() {
    query="$1"
    key="$2"
    [ -n "$query" ] || return 1

    old_ifs=$IFS
    IFS='&'
    set -- $query
    IFS=$old_ifs

    for pair in "$@"; do
        case "$pair" in
            "$key")
                printf '\n'
                return 0
                ;;
            "$key="*)
                xray_env_urldecode "${pair#*=}"
                return 0
                ;;
        esac
    done

    return 1
}

xray_env_reset_outbound() {
    prefix="$1"
    eval "unset ${prefix}_HOST ${prefix}_PORT ${prefix}_UUID ${prefix}_SNI ${prefix}_FP ${prefix}_PBK ${prefix}_SID"
}

xray_env_parse_hostport() {
    hostport="$1"

    case "$hostport" in
        \[*\]*)
            XRAY_ENV_PARSED_HOST=${hostport#\[}
            XRAY_ENV_PARSED_HOST=${XRAY_ENV_PARSED_HOST%%]*}
            rest=${hostport#*\]}
            case "$rest" in
                "") XRAY_ENV_PARSED_PORT=443 ;;
                :*) XRAY_ENV_PARSED_PORT=${rest#:} ;;
                *) xray_env_die "invalid host:port segment in VLESS URL: $hostport"; return 1 ;;
            esac
            ;;
        *:*)
            XRAY_ENV_PARSED_HOST=${hostport%:*}
            XRAY_ENV_PARSED_PORT=${hostport##*:}
            ;;
        *)
            XRAY_ENV_PARSED_HOST=$hostport
            XRAY_ENV_PARSED_PORT=443
            ;;
    esac

    [ -n "$XRAY_ENV_PARSED_HOST" ] || {
        xray_env_die "host missing in VLESS URL"
        return 1
    }

    case "$XRAY_ENV_PARSED_PORT" in
        *[!0-9]*|'')
            xray_env_die "port must be numeric in VLESS URL"
            return 1
            ;;
    esac

    [ "$XRAY_ENV_PARSED_PORT" -ge 1 ] 2>/dev/null && [ "$XRAY_ENV_PARSED_PORT" -le 65535 ] 2>/dev/null || {
        xray_env_die "port out of range in VLESS URL: $XRAY_ENV_PARSED_PORT"
        return 1
    }
}

xray_env_require_mode() {
    prefix="$1"
    label="$2"
    actual="$3"
    expected="$4"

    [ -z "$actual" ] && return 0
    [ "$actual" = "$expected" ] && return 0

    xray_env_die "${prefix}_VLESS_URL has unsupported ${label}: expected ${expected}, got ${actual}"
    return 1
}

xray_env_assign_if_set() {
    prefix="$1"
    suffix="$2"
    value="$3"

    [ -n "$value" ] || return 0
    eval "${prefix}_${suffix}=\$value"
}

xray_env_parse_vless_url() {
    prefix="$1"
    url="$2"

    case "$url" in
        vless://*) : ;;
        *)
            xray_env_die "${prefix}_VLESS_URL must start with vless://"
            return 1
            ;;
    esac

    body=${url#vless://}
    body=${body%%#*}

    case "$body" in
        *\?*)
            authority=${body%%\?*}
            query=${body#*\?}
            ;;
        *)
            authority=$body
            query=""
            ;;
    esac

    case "$authority" in
        *@*)
            uuid_enc=${authority%@*}
            hostport=${authority#*@}
            ;;
        *)
            xray_env_die "${prefix}_VLESS_URL must contain uuid@host"
            return 1
            ;;
    esac

    uuid=$(xray_env_urldecode "$uuid_enc")
    [ -n "$uuid" ] || {
        xray_env_die "${prefix}_VLESS_URL uuid is empty"
        return 1
    }

    xray_env_parse_hostport "$hostport" || return 1
    host=$(xray_env_urldecode "$XRAY_ENV_PARSED_HOST")
    port=$XRAY_ENV_PARSED_PORT

    type=$(xray_env_query_get "$query" type 2>/dev/null || true)
    security=$(xray_env_query_get "$query" security 2>/dev/null || true)
    encryption=$(xray_env_query_get "$query" encryption 2>/dev/null || true)
    flow=$(xray_env_query_get "$query" flow 2>/dev/null || true)
    header_type=$(xray_env_query_get "$query" headerType 2>/dev/null || true)

    xray_env_require_mode "$prefix" type "$type" tcp || return 1
    xray_env_require_mode "$prefix" security "$security" reality || return 1
    xray_env_require_mode "$prefix" encryption "$encryption" none || return 1
    xray_env_require_mode "$prefix" flow "$flow" xtls-rprx-vision || return 1
    xray_env_require_mode "$prefix" headerType "$header_type" none || return 1

    sni=$(xray_env_query_get "$query" sni 2>/dev/null || true)
    [ -n "$sni" ] || sni=$(xray_env_query_get "$query" serverName 2>/dev/null || true)
    fp=$(xray_env_query_get "$query" fp 2>/dev/null || true)
    [ -n "$fp" ] || fp=$(xray_env_query_get "$query" fingerprint 2>/dev/null || true)
    pbk=$(xray_env_query_get "$query" pbk 2>/dev/null || true)
    [ -n "$pbk" ] || pbk=$(xray_env_query_get "$query" publicKey 2>/dev/null || true)
    sid=$(xray_env_query_get "$query" sid 2>/dev/null || true)
    [ -n "$sid" ] || sid=$(xray_env_query_get "$query" shortId 2>/dev/null || true)

    eval "${prefix}_HOST=\$host"
    eval "${prefix}_PORT=\$port"
    eval "${prefix}_UUID=\$uuid"
    xray_env_assign_if_set "$prefix" SNI "$sni"
    xray_env_assign_if_set "$prefix" FP "$fp"
    xray_env_assign_if_set "$prefix" PBK "$pbk"
    xray_env_assign_if_set "$prefix" SID "$sid"
}

xray_load_env() {
    repo_file=$(xray_env_repo_file)
    secret_file=$(xray_env_secret_file)

    if [ -r "$repo_file" ]; then
        # shellcheck disable=SC1090
        . "$repo_file"
    fi

    if [ -r "$secret_file" ]; then
        # shellcheck disable=SC1090
        . "$secret_file"
    fi

    if [ -n "${T_VLESS_URL:-}" ]; then
        xray_env_reset_outbound T
        xray_env_parse_vless_url T "$T_VLESS_URL" || return 1
    fi

    if [ -n "${A_VLESS_URL:-}" ]; then
        xray_env_reset_outbound A
        xray_env_parse_vless_url A "$A_VLESS_URL" || return 1
    fi

    : "${T_PORT:=443}"
    : "${A_PORT:=443}"
    : "${T_FP:=chrome}"
    : "${A_FP:=chrome}"

    export REPO_RAW GEOSITE_URL GEOIP_URL GEOSITE_CUSTOM_URL
    export LISTS_R_T_IPV4_URL LISTS_R_A_IPV4_URL LISTS_R_T_DOMAINS_URL LISTS_R_A_DOMAINS_URL
    export LISTS_C_D_IPV4_URL LISTS_C_T_IPV4_URL LISTS_C_A_IPV4_URL
    export LISTS_C_D_DOMAINS_URL LISTS_C_T_DOMAINS_URL LISTS_C_A_DOMAINS_URL
    export LISTS_C_T_DST_V4_URL LISTS_C_A_DST_V4_URL
    export ALLOW_DOMAINS_BASE
    export LAN_IF CLIENT_DST_MIN_PREFIX
    export XRAY_ACCESS_LOG_MAX_BYTES XRAY_ACCESS_LOG_KEEP_BYTES
    export XRAY_ERROR_LOG_MAX_BYTES XRAY_ERROR_LOG_KEEP_BYTES
    export XRAY_CRON_LOG_MAX_BYTES XRAY_CRON_LOG_KEEP_BYTES
    export XRAY_TEST_LOG_MAX_BYTES XRAY_TEST_LOG_KEEP_BYTES
    export T_VLESS_URL A_VLESS_URL
    export T_HOST T_PORT T_UUID T_SNI T_FP T_PBK T_SID
    export A_HOST A_PORT A_UUID A_SNI A_FP A_PBK A_SID
}

xray_env_require_vars() {
    missing=""

    for name in "$@"; do
        eval "value=\${$name:-}"
        [ -n "$value" ] || missing="${missing:+$missing }$name"
    done

    [ -z "$missing" ] && return 0

    xray_env_die "missing required env vars: $missing"
    return 1
}

xray_env_require_outbound() {
    prefix="$1"
    xray_env_require_vars \
        "${prefix}_HOST" \
        "${prefix}_PORT" \
        "${prefix}_UUID" \
        "${prefix}_SNI" \
        "${prefix}_FP" \
        "${prefix}_PBK" \
        "${prefix}_SID"
}

xray_env_stack_ready() {
    xray_env_require_vars REPO_RAW GEOSITE_URL GEOIP_URL || return 1
    xray_env_require_outbound T || return 1
    xray_env_require_outbound A || return 1
}
