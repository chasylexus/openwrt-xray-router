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

        # 3. never touch local / private destinations
        ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4 } return

        # 4. policy (A before T: A wins on IP overlap)
        ip daddr @r_A_v4 counter redirect to :10802 comment "router -> A"
        ip daddr @r_T_v4 counter redirect to :10801 comment "router -> T"

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
