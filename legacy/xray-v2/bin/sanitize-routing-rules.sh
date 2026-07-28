#!/bin/sh
# sanitize-routing-rules.sh
#
# Drop overly broad IPv4 and IPv6 CIDRs from rendered Xray routing rules.
# Intended for managed xray/50-routing.json after template rendering, before
# xray -test. Bare IPv4 entries always pass; only CIDRs broader than the
# configured threshold are removed.
#
# Env:
#   XRAY_RULE_MIN_PREFIX    - minimum prefix length accepted for IPv4 CIDRs in
#                             "ip"/"source" arrays (default 17)
#   XRAY_RULE_MIN_PREFIX6   - minimum prefix length accepted for IPv6 CIDRs in
#                             "ip"/"source" arrays (default 32)

set -eu

in="${1:-}"
out="${2:-}"

[ -n "$in" ]  || { echo "usage: $0 <input-json> <output-json>" >&2; exit 2; }
[ -n "$out" ] || { echo "usage: $0 <input-json> <output-json>" >&2; exit 2; }
[ -r "$in" ]  || { echo "input not readable: $in" >&2; exit 2; }

: "${XRAY_RULE_MIN_PREFIX:=17}"
: "${XRAY_RULE_MIN_PREFIX6:=32}"

awk -v threshold4="$XRAY_RULE_MIN_PREFIX" -v threshold6="$XRAY_RULE_MIN_PREFIX6" -v src="$in" '
function reset_array(    i) {
    in_array = 0
    key = ""
    start_line = ""
    close_line = ""
    count = 0
    kept = 0
    filtered = 0
    for (i = 1; i <= 1024; i++) {
        delete item[i]
        delete keep[i]
    }
}

function trim_trailing_comma(s) {
    sub(/,[[:space:]]*$/, "", s)
    return s
}

function flush_array(    i, printed, line) {
    print start_line
    printed = 0
    for (i = 1; i <= count; i++) {
        if (!keep[i]) {
            continue
        }
        line = trim_trailing_comma(item[i])
        printed++
        if (printed < kept) {
            line = line ","
        }
        print line
    }
    if (filtered > 0 && kept == 0) {
        printf "[sanitize-routing][WARN] %s array in %s became empty after width filter\n", key, src > "/dev/stderr"
    }
    print close_line
    reset_array()
}

BEGIN {
    reset_array()
}

{
    line = $0

    if (!in_array) {
        if (line ~ /^[[:space:]]*"(ip|source)"[[:space:]]*:[[:space:]]*\[/ &&
            line !~ /\][[:space:]]*,?[[:space:]]*$/) {
            in_array = 1
            start_line = line
            key = (line ~ /"source"/) ? "source" : "ip"
            next
        }
        print line
        next
    }

    if (line ~ /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/) {
        close_line = line
        flush_array()
        next
    }

    count++
    item[count] = line
    keep[count] = 1

    if (line ~ /"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/) {
        cidr = line
        sub(/^[^"]*"/, "", cidr)
        sub(/".*$/, "", cidr)
        prefix = cidr
        sub(/^.*\//, "", prefix)
        if ((prefix + 0) < (threshold4 + 0)) {
            printf "[sanitize-routing][reject %s] CIDR %s broader than /%s in %s\n",
                key, cidr, threshold4, src > "/dev/stderr"
            keep[count] = 0
            filtered++
        } else {
            kept++
        }
    } else if (line ~ /"[0-9A-Fa-f:]+\/[0-9]+"/) {
        cidr = line
        sub(/^[^"]*"/, "", cidr)
        sub(/".*$/, "", cidr)
        prefix = cidr
        sub(/^.*\//, "", prefix)
        if ((prefix + 0) < (threshold6 + 0)) {
            printf "[sanitize-routing][reject %s] CIDR %s broader than /%s in %s\n",
                key, cidr, threshold6, src > "/dev/stderr"
            keep[count] = 0
            filtered++
        } else {
            kept++
        }
    } else {
        kept++
    }
}

END {
    if (in_array) {
        printf "[sanitize-routing][FATAL] unterminated %s array in %s\n", key, src > "/dev/stderr"
        exit 1
    }
}
' "$in" > "$out"
