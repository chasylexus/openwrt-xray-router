#
# OPTIONAL BONUS LAYER — dnsmasq raw confdir snippet.
#
# This file is NOT required for the critical path. The system works with just
# static lists and update-sets.sh. dnsmasq nftset only adds lazy DNS-driven
# filling of the same sets, which shortens the window where a user hits a
# brand-new domain before update-sets.sh catches it.
#
# NOTE: we deliberately do NOT use UCI `list nftset` — it does not work
# reliably on this OpenWrt build. This is raw dnsmasq syntax, consumed by
# dnsmasq's confdir.
#
# Syntax:
#   nftset=/<domain>/<ip-family>#<family>#<table>#<set>
#   (repeated for multiple sets)
#
# We attach one line per client-side domain category. Router-side domains
# are NOT attached here — router does its own DNS via system resolver; adding
# them to dnsmasq nftset would fill client-side tables with router-only
# resolutions.
#
# If you want to extend this list, add more `nftset=` directives below.
# Any parse error => dnsmasq refuses to start; update-managed-stack.sh
# catches this because dnsmasq reload returns non-zero.
#

# Hook typical domain prefixes. Individual domains are better handled by
# explicit resolution in update-sets.sh, but dnsmasq can pick up subdomain
# wildcards that our static lists miss.

# Proxy T target tag (c_T_v4)
#   example: route a domain subtree through T on DNS lookup
# nftset=/example-t.com/4#inet#xray_clients#c_T_v4

# Proxy A target tag (c_A_v4)
#   example: route a domain subtree through A on DNS lookup
# nftset=/example-a.com/4#inet#xray_clients#c_A_v4

# Direct tag (c_D_v4)
#   example: ensure a domain is resolved into the direct set
# nftset=/example-direct.com/4#inet#xray_clients#c_D_v4

# Leave this file empty (only comments) in production if you want to rely
# solely on the static/merged lists and skip the bonus layer altogether.
