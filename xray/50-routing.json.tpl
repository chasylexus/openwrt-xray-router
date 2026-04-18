{
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "domainMatcher": "hybrid",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["r-T-in"],
        "outboundTag": "T"
      },
      {
        "type": "field",
        "inboundTag": ["r-A-in"],
        "outboundTag": "A"
      },
      {
        "type": "field",
        "inboundTag": ["c-D-in"],
        "outboundTag": "D"
      },
      {
        "type": "field",
        "inboundTag": ["c-T-in"],
        "outboundTag": "T"
      },
      {
        "type": "field",
        "inboundTag": ["c-A-in"],
        "outboundTag": "A"
      },

      {
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "B"
      },
      {
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": ["geosite:private", "geosite:cn", "geosite:geolocation-cn"],
        "outboundTag": "D"
      },
      {
        "type": "field",
        "inboundTag": ["c-def-in"],
        "ip": ["geoip:private", "geoip:cn"],
        "outboundTag": "D"
      },
      {
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": ["geosite:geolocation-ru"],
        "outboundTag": "D"
      },
      {
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": ["geosite:openai", "geosite:anthropic", "geosite:category-ai-!cn"],
        "outboundTag": "A"
      },
      {
        "type": "field",
        "inboundTag": ["c-def-in"],
        "outboundTag": "T"
      }
    ]
  }
}
