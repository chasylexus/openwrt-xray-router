#
# xray_clients — policy routing for LAN client TCP traffic passing through router.
# Hook: nat/prerouting, interface __LAN_IF__ (default br-lan).
# Anti-loop: packets originating on the router never hit this chain.
#
# Rendered from: 20-clients-prerouting.nft.tpl
# Source of truth for set membership: update-sets.sh (+ optional dnsmasq fill)
#
# UDP is intentionally NOT intercepted here. See README design notes.
# To add UDP later, switch to TPROXY + ip rule fwmark + local table.
#

table inet xray_clients {

    set c_D_v4 {
        type ipv4_addr
        flags interval
        auto-merge
    }

    set c_T_v4 {
        type ipv4_addr
        flags interval
        auto-merge
    }

    set c_A_v4 {
        type ipv4_addr
        flags interval
        auto-merge
    }

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

        # 4. never touch local / private destinations
        ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4 } return

        # 5. explicit D: direct path, do not hop through Xray at all
        ip daddr @c_D_v4 counter return comment "client -> D (direct)"

        # 6. explicit T / A
        ip daddr @c_T_v4 counter redirect to :10811 comment "client -> T"
        ip daddr @c_A_v4 counter redirect to :10812 comment "client -> A"

        # 7. fallback: default Xray inbound handles it by domain/geosite/geoip
        counter redirect to :10813 comment "client -> c-def-in (fallback)"
    }
}
