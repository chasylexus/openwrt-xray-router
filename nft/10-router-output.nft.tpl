#
# xray_router — policy routing for the router's own outbound TCP traffic.
# Hook: nat/output.
# Anti-loop: skip packets whose socket has mark 0xff (set by Xray outbounds).
#
# Rendered from: 10-router-output.nft.tpl
# Source of truth for set membership: update-sets.sh
#

table inet xray_router {

    set r_T_v4 {
        type ipv4_addr
        flags interval
        auto-merge
    }

    set r_A_v4 {
        type ipv4_addr
        flags interval
        auto-merge
    }

    chain output {
        type nat hook output priority -100; policy accept;

        # 1. anti-loop: Xray's own outbound sockets
        meta mark 0xff return

        # 2. IPv4 only, TCP only
        meta nfproto ipv4 counter comment "xray_router: ipv4 out"
        meta l4proto != tcp return

        # 3. never touch local / private / special-use destinations
        ip daddr {
            10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16,
            172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.88.99.0/24,
            192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24,
            203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4
        } return

        # 4. policy (A before T: A wins on IP overlap).
        #    `meta l4proto tcp` is required on each `redirect to :port`
        #    rule — nft parser needs transport-proto matched *in the
        #    same rule* for `redirect to :port` (the earlier
        #    `meta l4proto != tcp return` guard is not enough).
        meta l4proto tcp ip daddr @r_A_v4 counter redirect to :10802 comment "router -> A"
        meta l4proto tcp ip daddr @r_T_v4 counter redirect to :10801 comment "router -> T"

        # 5. else: system default (direct)
    }

    # Visibility counters (no-op chain useful for `nft list ruleset` reading)
    chain diag {
        type filter hook output priority 0; policy accept;
        meta mark 0xff counter comment "bypass"
        ip daddr @r_A_v4 counter comment "seen r_A_v4"
        ip daddr @r_T_v4 counter comment "seen r_T_v4"
    }
}
