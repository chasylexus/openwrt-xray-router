{
  "inbounds": [
    {
      "_comment": "Router-side: REDIRECT on loopback, TCP only. No TPROXY needed — nat/output chain captures router's own sockets via r_T_v4 / r_A_v4 IP sets in nft/10-router-output.nft.tpl.",
      "tag": "r-T-in",
      "listen": "127.0.0.1",
      "port": 10801,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "routeOnly": false
      }
    },
    {
      "tag": "r-A-in",
      "listen": "127.0.0.1",
      "port": 10802,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "routeOnly": false
      }
    },
    {
      "_comment": "Router-side IPv6: same redirect model as r-T-in/r-A-in, but bound on ::1 with distinct ports so IPv4 and IPv6 stay explicit in diagnostics and nft rules.",
      "tag": "r-T6-in",
      "listen": "::1",
      "port": 10821,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "routeOnly": false
      }
    },
    {
      "tag": "r-A6-in",
      "listen": "::1",
      "port": 10822,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "routeOnly": false
      }
    },
    {
      "_comment": "Client-side per-IP T: TPROXY for TCP + UDP. nft prerouting tproxies destinations from the c_T_dst_v4 set here; xray routes inboundTag=c-T-in -> T unconditionally (xray/50-routing.json.tpl). Sniffing is on so xray-access.log still shows the SNI/QUIC SNI for diagnostics, but routing does not depend on it.",
      "tag": "c-T-in",
      "listen": "0.0.0.0",
      "port": 10811,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      }
    },
    {
      "_comment": "Client-side per-IP A: same shape as c-T-in, distinct port -> distinct inbound -> distinct outbound (A).",
      "tag": "c-A-in",
      "listen": "0.0.0.0",
      "port": 10812,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      }
    },
    {
      "_comment": "Client-side IPv6 per-IP T: same shape as c-T-in but explicit ::1 bind + dedicated port so nft can steer IPv6 by family without relying on dual-stack socket semantics.",
      "tag": "c-T6-in",
      "listen": "::1",
      "port": 10831,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      }
    },
    {
      "tag": "c-A6-in",
      "listen": "::1",
      "port": 10832,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      }
    },
    {
      "_comment": "Client-side default: TPROXY for TCP + UDP. Binds 0.0.0.0:10813. `sockopt.tproxy = tproxy` sets IP_TRANSPARENT + IP_RECVORIGDSTADDR so xray sees the original destination. `destOverride` includes `quic` so HTTP/3 ClientHello SNI is extracted.",
      "tag": "c-def-in",
      "listen": "0.0.0.0",
      "port": 10813,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      }
    },
    {
      "_comment": "Client-side IPv6 default path: mirrors c-def-in on a dedicated IPv6 loopback socket/port.",
      "tag": "c-def6-in",
      "listen": "::1",
      "port": 10833,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      }
    }
  ]
}
