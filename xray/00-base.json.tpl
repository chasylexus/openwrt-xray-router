{
  "log": {
    "loglevel": "info",
    "access": "/tmp/xray-access.log",
    "error": "/tmp/xray-error.log"
  },
  "dns": {
    "servers": [
      __XRAY_DNS_SERVERS_JSON__
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
