{
  "inbounds": [
    {
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
      "tag": "c-def-in",
      "listen": "0.0.0.0",
      "port": 10813,
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
    }
  ]
}
