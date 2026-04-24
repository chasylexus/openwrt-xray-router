{
  "log": {
    "loglevel": "info",
    "access": "/tmp/xray-access.log",
    "error": "/tmp/xray-error.log"
  },
  "dns": {
    "servers": [
      "127.0.0.1",
      "1.1.1.1",
      "8.8.8.8"
    ],
    "queryStrategy": "__XRAY_DNS_QUERY_STRATEGY__"
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 120,
        "uplinkOnly": 2,
        "downlinkOnly": 5
      }
    },
    "system": {
      "statsInboundUplink": false,
      "statsInboundDownlink": false
    }
  }
}
