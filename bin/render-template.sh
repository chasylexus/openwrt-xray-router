#!/bin/sh
# render-template.sh
#
# POSIX-safe template renderer. Replaces __TOKEN__ placeholders on stdin/path
# with values from an env-file or current environment.
#
# Usage:
#   render-template.sh <template-path> [env-file]
#
# env-file: shell-compatible key=value (will be sourced). Default: /etc/xray/secret.env
#
# Only placeholders of the form __UPPER_UNDERSCORE__ are considered.
# Missing tokens => non-zero exit. Extra env vars are ignored.
# Output goes to stdout.

set -eu

tpl="${1:-}"
env_file="${2:-/etc/xray/secret.env}"

if [ -z "$tpl" ] || [ ! -r "$tpl" ]; then
    echo "usage: $0 <template> [env-file]" >&2
    echo "template not readable: $tpl" >&2
    exit 2
fi

if [ -r "$env_file" ]; then
    # shellcheck disable=SC1090
    . "$env_file"
fi

# Keep older installs rendering successfully if these optional fingerprint
# vars are absent in secret.env. Routers that set T_FP/A_FP override these.
: "${T_FP:=chrome}"
: "${A_FP:=chrome}"

# collect every __TOKEN__ in the template
tokens=$(grep -oE '__[A-Z0-9_]+__' "$tpl" | sort -u || true)

# build a sed script
sed_cmds=""
missing=""

for tk in $tokens; do
    key=$(printf '%s' "$tk" | sed 's/^__//; s/__$//')
    # expand via eval (keys are [A-Z0-9_]+ — safe charset)
    eval "val=\${$key-__UNSET__}"
    # shellcheck disable=SC2154  # 'val' is assigned via eval above
    if [ "$val" = "__UNSET__" ]; then
        missing="$missing $key"
        continue
    fi
    # escape for sed RHS: &, \, /, and delimiter (we use |)
    esc=$(printf '%s' "$val" | sed -e 's/[\\&|]/\\&/g')
    sed_cmds="${sed_cmds}s|${tk}|${esc}|g;"
done

if [ -n "$missing" ]; then
    echo "render-template: missing env vars:$missing" >&2
    exit 3
fi

if [ -z "$sed_cmds" ]; then
    cat "$tpl"
else
    sed "$sed_cmds" "$tpl"
fi
