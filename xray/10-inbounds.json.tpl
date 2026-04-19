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
    }
  ]
}
