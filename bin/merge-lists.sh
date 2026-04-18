#!/bin/sh
# merge-lists.sh
#
# Merge local + remote lists for each list name into /etc/xray/lists/merged.
# Pure text processing; no resolution here (that's update-sets.sh).
#
# Input (priority: local overrides remote — but we UNION them, we do not replace):
#   /etc/xray/lists/local/<name>.txt
#   /etc/xray/lists/remote/<name>.txt
#
# Output:
#   /etc/xray/lists/merged/<name>.txt
#
# Format of list files:
#   - one entry per line (domain or IPv4, depending on list)
#   - '#' starts a comment
#   - empty lines ignored
#   - whitespace stripped

set -eu

XRAY_ROOT="/etc/xray"
L="$XRAY_ROOT/lists/local"
R="$XRAY_ROOT/lists/remote"
M="$XRAY_ROOT/lists/merged"

mkdir -p "$M"

LISTS='
r-T-ipv4.txt r-A-ipv4.txt
r-T-domains.txt r-A-domains.txt
c-D-ipv4.txt c-T-ipv4.txt c-A-ipv4.txt
c-D-domains.txt c-T-domains.txt c-A-domains.txt
'

for name in $LISTS; do
    tmp="$M/.${name}.staged.$$"
    {
        [ -r "$L/$name" ] && cat "$L/$name"
        [ -r "$R/$name" ] && cat "$R/$name"
    } \
    | sed -e 's/#.*$//' -e 's/[[:space:]]\{1,\}//g' \
    | grep -v '^$' \
    | sort -u > "$tmp"
    mv "$tmp" "$M/$name"
done

printf '[merge-lists] OK\n'
