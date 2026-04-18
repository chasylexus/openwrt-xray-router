#
# xray_clients — dumb transparent redirect for LAN client TCP.
# Hook: nat/prerouting, interface __LAN_IF__ (default br-lan).
# Anti-loop: packets originating on the router never hit this chain.
#
# Rendered from: 20-clients-prerouting.nft.tpl
#
# Design note — SIMPLIFIED from the earlier per-set-match architecture:
#
#   Previous: c_D_v4/c_T_v4/c_A_v4 sets filled by update-sets.sh +
#   dnsmasq nftset, matched at nft level so xray saw traffic pre-split
#   by outbound. Sounded fast, but shared CDN IPs (AWS/Google) between
#   listed and unlisted domains caused wrong-outbound routing — e.g.
#   api.ipify.org going through A because its IP overlapped with
#   ai.google.dev.
#
#   Now: nft just redirects every LAN TCP flow (minus private dst) to a
#   single xray inbound c-def-in:10813. xray does sniff + domain-based
#   routing with zero IP-collision ambiguity. Router-side (nat/output)
#   still uses r_T_v4/r_A_v4 because there the set is small and stable.
#
# UDP is intentionally NOT intercepted here. See README design notes.
# To add UDP later, switch to TPROXY + ip rule fwmark + local table.
#

table inet xray_clients {

    chain prerouting {
        type nat hook prerouting priority -100; policy accept;

        # 1. anti-loop: defensive — prerouting does not normally see local-origin
        #    packets, but tproxy/tproxy-like configs can confuse that. Cheap.
        meta mark 0xff return

        # 2. only traffic arriving on LAN
        iifname != "__LAN_IF__" return

        # 3. IPv4 TCP only
        meta nfproto ipv4 counter comment "xray_clients: ipv4 in"
        meta l4proto != tcp return

        # 4. never touch local / private destinations (LAN-to-LAN, loopback, link-local, multicast)
        ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4 } return

        # 5. redirect EVERYTHING else to xray c-def-in.
        #    `meta l4proto tcp` must be on every rule that contains
        #    `redirect to :port` (nft parser requirement).
        meta l4proto tcp counter redirect to :10813 comment "client -> c-def-in (ALL)"
    }
}
