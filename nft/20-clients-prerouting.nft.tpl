#
# xray_clients — TPROXY transparent proxy for LAN client TCP + UDP.
# Hook: prerouting, filter-type at mangle priority.
# Interface: __LAN_IF__ (default br-lan).
#
# Rendered from: 20-clients-prerouting.nft.tpl
#
# --- Why TPROXY instead of REDIRECT ---
#
# REDIRECT (nat/prerouting) handles TCP only. QUIC is UDP 443 — it bypassed
# us entirely, and apps that prefer HTTP/3 (native ChatGPT / iOS Safari /
# macOS apps with alt-svc cached) leaked the real IP. TPROXY delivers both
# TCP and UDP to a local socket without rewriting the packet, so xray can
# sniff original destination + SNI + QUIC ClientHello alike.
#
# --- What decisions live at the nft layer ---
#
# We deliberately DO NOT do per-outbound routing here (no c_T_v4/c_A_v4/...).
# That was the pre-7f118eb design; it failed on CDN-shared IPs, e.g.
# api.ipify.org landing in c_A_v4 via a Google-AI IP collision.
#
# nft is the right place for decisions that are stable by IP alone:
#   - anti-loop (mark 0xff)
#   - interface filter (only LAN-originated)
#   - user-curated bypass (c_bypass_dst_v4, c_bypass_src_v4)
#   - private / loopback / multicast destinations
#
# Everything else is TPROXY'd into c-def-in:10813 where xray makes the
# outbound choice based on sniffed domain — the only reliable source of
# truth in a post-SNI-fronted, CDN-saturated internet.
#
# --- Anti-loop ---
#
# Xray outbounds are configured with sockopt.mark = 0xff. Those packets
# bypass this chain via the first rule. Double-checked against
# apply-iprules.sh, which also points mark 0xff at the main table —
# defense-in-depth.
#

table inet xray_clients {

    # ---- user-curated bypass sets ----
    #
    # Populated by update-sets.sh from /etc/xray/lists/.../c-bypass-*.txt.
    # Static IPs only — never put CDN IPs here (Cloudflare / Google edge
    # serves dozens of unrelated services per IP; bypassing by IP means
    # bypassing unrelated traffic you probably wanted proxied).
    #
    # Good examples: your VPS IP (defense-in-depth), 1.1.1.1 / 8.8.8.8 if
    # you want direct DNS, local NAS public IP, banks that dislike proxies.
    #
    set c_bypass_dst_v4 {
        type ipv4_addr
        flags interval
        auto-merge
    }

    # Source bypass — "this LAN device is never proxied".
    # Good examples: IoT, game consoles, guest devices with their own VPN,
    # a control laptop you keep on direct for A/B comparison.
    #
    set c_bypass_src_v4 {
        type ipv4_addr
    }

    # ---- prerouting: the TPROXY hook ----
    #
    # Priority mangle (-150): runs after conntrack init (-200) but before
    # any nat hook (nat/prerouting is -100, fw4's dstnat similar). We need
    # to be BEFORE nat so we can grab the packet untouched.
    #
    chain prerouting {
        type filter hook prerouting priority -150; policy accept;

        # 1. Anti-loop: xray-own outbound sockets (SO_MARK=0xff).
        #    Must be first — these packets should never feed back into us.
        meta mark 0xff return

        # 2. Only LAN-originated traffic.
        iifname != "__LAN_IF__" return

        # 3. User bypass — destinations (e.g. VPS IP, direct-DNS, banks).
        ip daddr @c_bypass_dst_v4 counter return comment "user bypass: dst"

        # 4. User bypass — source clients (e.g. IoT, consoles).
        ip saddr @c_bypass_src_v4 counter return comment "user bypass: src"

        # 5. Private / LAN-local / multicast / broadcast never cross the proxy.
        # 0.0.0.0/8   — DHCPDISCOVER from a client without an IP yet.
        # 240.0.0.0/4 — reserved range; covers 255.255.255.255 limited
        #               broadcast (DHCP renewal, SSDP, some L2 discovery).
        ip daddr {
            0.0.0.0/8, 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12,
            192.168.0.0/16, 169.254.0.0/16,
            224.0.0.0/4, 240.0.0.0/4
        } return comment "private / LAN-local / multicast / broadcast"

        # 5b. IPv6 local / link-local / unique-local / multicast.
        # Without this, IPv6-enabled LAN traffic (mDNS ff02::fb, Neighbor
        # Discovery, link-local fe80::/10) leaks into TPROXY. The inet
        # table matches both families, so we must exempt v6 explicitly.
        ip6 daddr { ::1/128, fc00::/7, fe80::/10, ff00::/8 } \
            return comment "IPv6 local / link-local / multicast"

        # 6. TCP -> c-def-in. xray sniffs HTTP Host / TLS SNI, decides
        #    outbound by domain rule in xray/50-routing.json.tpl.
        meta l4proto tcp tproxy to :10813 meta mark set 0x1 counter \
            comment "TCP -> c-def-in (sniff + domain routing)"

        # 7. UDP -> c-def-in. xray sniffs QUIC ClientHello (SNI), decides
        #    the same way. Without this, HTTP/3 (UDP 443) leaks past us
        #    and apps see the real IP — the whole reason we moved off
        #    REDIRECT.
        meta l4proto udp tproxy to :10813 meta mark set 0x1 counter \
            comment "UDP -> c-def-in (QUIC sniff)"
    }

    # ---- diagnostics (no-op, readable via `nft list ruleset`) ----
    chain diag {
        type filter hook prerouting priority 0; policy accept;
        meta mark 0xff counter comment "xray-own (bypass)"
        ip daddr @c_bypass_dst_v4 counter comment "bypass dst hits"
        ip saddr @c_bypass_src_v4 counter comment "bypass src hits"
    }
}
