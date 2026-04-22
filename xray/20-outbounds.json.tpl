{
  "outbounds": [
    {
      "tag": "T",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "__T_HOST__",
            "port": __T_PORT__,
            "users": [
              {
                "id": "__T_UUID__",
                "flow": "xtls-rprx-vision",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "__T_SNI__",
          "fingerprint": "__T_FP__",
          "publicKey": "__T_PBK__",
          "shortId": "__T_SID__",
          "spiderX": ""
        },
        "sockopt": {
          "mark": 255
        }
      }
    },
    {
      "tag": "A",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "__A_HOST__",
            "port": __A_PORT__,
            "users": [
              {
                "id": "__A_UUID__",
                "flow": "xtls-rprx-vision",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "__A_SNI__",
          "fingerprint": "__A_FP__",
          "publicKey": "__A_PBK__",
          "shortId": "__A_SID__",
          "spiderX": ""
        },
        "sockopt": {
          "mark": 255
        }
      }
    },
    {
      "tag": "D",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "streamSettings": {
        "sockopt": {
          "mark": 255
        }
      }
    },
    {
      "tag": "B",
      "protocol": "blackhole",
      "settings": {}
    }
  ]
}
