{
  "log": {
    "level": "warn"
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "store_rdrc": true,
      "store_fakeip": true
    },
    "clash_api": {
      "external_controller": "127.0.0.1:9090"
    }
  },
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns-direct",
        "server": "__UPSTREAM_DNS__",
        "server_port": 53
      },
      {
        "type": "fakeip",
        "tag": "fakeip",
        "inet4_range": "198.18.0.0/15"
      }
    ],
    "rules": [
      {
        "query_type": [
          "HTTPS",
          "SVCB"
        ],
        "server": "dns-direct"
      },
      {
        "domain_suffix": [
          "s3.dualstack.eu-west-1.amazonaws.com"
        ],
        "server": "fakeip"
      },
      {
        "domain_suffix": [
          "voidboost.one"
        ],
        "domain_regex": [
          "(^|\\.)voidboost\\.[a-z0-9-]+$"
        ],
        "server": "fakeip"
      },
      {
        "rule_set": [
          "manual-d"
        ],
        "server": "dns-direct"
      },
      {
        "domain_suffix": [
          "dub.sh",
          "dub.co",
          "microiptv.org"
        ],
        "server": "fakeip"
      },
      {
        "domain_suffix": [
          "lostfilm.download",
          "lostfilm.tv"
        ],
        "server": "fakeip"
      },
      {
        "rule_set": [
          "manual-t-priority",
          "manual-google-ai",
          "manual-t",
          "openai",
          "anthropic",
          "ai-not-cn",
          "youtube",
          "spotify",
          "lastfm",
          "facebook",
          "instagram",
          "whatsapp",
          "twitter",
          "telegram",
          "tiktok",
          "discord",
          "linkedin",
          "microsoft",
          "google",
          "wikimedia",
          "bbc",
          "cnn",
          "kinopub",
          "manual-t-late"
        ],
        "server": "fakeip"
      },
      {
        "rule_set": [
          "manual-a",
          "netflix",
          "hulu",
          "disney",
          "hbo",
          "espn",
          "primevideo"
        ],
        "server": "fakeip"
      }
    ],
    "final": "dns-direct",
    "independent_cache": true
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "sb-tun0",
      "address": [
        "172.19.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "mtu": 9000,
      "stack": "gvisor",
      "auto_route": true,
      "route_exclude_address": [
        "0.0.0.0/8",
        "10.0.0.0/8",
        "100.64.0.0/10",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "224.0.0.0/4",
        "240.0.0.0/4",
        "255.255.255.255/32",
        "::/128",
        "::1/128",
        "fc00::/7",
        "fe80::/10",
        "ff00::/8",
      "__TT_ENDPOINT_IPV4__/32"
      ],
      "auto_redirect": false
    },
    {
      "type": "direct",
      "tag": "dns-in",
      "listen": "127.0.0.1",
      "listen_port": 1053,
      "override_address": "1.1.1.1",
      "override_port": 53
    },
    {
      "type": "mixed",
      "tag": "router-test-in",
      "listen": "127.0.0.1",
      "listen_port": 10809
    },
    {
      "type": "mixed",
      "tag": "tailscale-underlay-in",
      "listen": "127.0.0.1",
      "listen_port": 10810
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct",
      "bind_interface": "__WAN_INTERFACE__"
    },
    {
      "type": "socks",
      "tag": "tt-t",
      "server": "127.0.0.1",
      "server_port": 11080,
      "version": "5"
    },
    {
      "type": "socks",
      "tag": "tt-a",
      "server": "127.0.0.1",
      "server_port": 11080,
      "version": "5"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "selector",
      "tag": "tailscale-underlay",
      "outbounds": [
        "tt-t",
        "direct"
      ],
      "default": "tt-t",
      "interrupt_exist_connections": true
    }
  ],
  "route": {
    "default_domain_resolver": "dns-direct",
    "rule_set": [
      {
        "type": "remote",
        "tag": "ads-all",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "manual-t-priority",
        "format": "source",
        "url": "__RULESET_BASE__/manual-t-priority.json",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "manual-d",
        "format": "source",
        "url": "__RULESET_BASE__/manual-d.json",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "manual-a",
        "format": "source",
        "url": "__RULESET_BASE__/manual-a.json",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "manual-google-ai",
        "format": "source",
        "url": "__RULESET_BASE__/manual-google-ai.json",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "netflix",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-netflix.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "hulu",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-hulu.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "disney",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-disney.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "hbo",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-hbo.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "espn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-espn.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "primevideo",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-primevideo.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "manual-t",
        "format": "source",
        "url": "__RULESET_BASE__/manual-t.json",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "manual-t-late",
        "format": "source",
        "url": "__RULESET_BASE__/manual-t-late.json",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "openai",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "anthropic",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-anthropic.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "ai-not-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ai-!cn.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "youtube",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-youtube.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "spotify",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-spotify.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "lastfm",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-lastfm.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "facebook",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-facebook.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "instagram",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-instagram.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "whatsapp",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-whatsapp.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "twitter",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-twitter.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "telegram",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-telegram.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "tiktok",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-tiktok.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "discord",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-discord.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "linkedin",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-linkedin.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "microsoft",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-microsoft.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "google",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "wikimedia",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-wikimedia.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "bbc",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-bbc.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "cnn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cnn.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      },
      {
        "type": "remote",
        "tag": "kinopub",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-kinopub.srs",
        "update_interval": "2h",
        "download_detour": "tt-t"
      }
    ],
    "rules": [
      {
        "inbound": [
          "tailscale-underlay-in"
        ],
        "outbound": "tailscale-underlay"
      },
      {
        "process_name": [
          "tailscaled"
        ],
        "outbound": "direct"
      },
      {
        "inbound": [
          "tun-in",
          "dns-in",
          "router-test-in"
        ],
        "action": "sniff"
      },
      {
        "domain_suffix": [
          "tailscale.com",
          "tailscale.io"
        ],
        "outbound": "tailscale-underlay"
      },
      {
        "protocol": [
          "dns"
        ],
        "action": "hijack-dns"
      },
      {
        "domain_suffix": [
          "dub.sh",
          "dub.co",
          "microiptv.org"
        ],
        "outbound": "tt-t"
      },
      {
        "ip_cidr": [
          "64.239.123.193/32",
          "64.239.109.193/32",
          "64.239.109.65/32",
          "66.33.60.66/32",
          "176.10.97.4/32"
        ],
        "outbound": "tt-t"
      },
      {
        "domain_suffix": [
          "lostfilm.download",
          "lostfilm.tv"
        ],
        "outbound": "tt-t"
      },
      {
        "domain_suffix": [
          "spinorama.org"
        ],
        "outbound": "tt-t"
      },
      {
        "domain_suffix": [
          "s3.dualstack.eu-west-1.amazonaws.com"
        ],
        "outbound": "tt-t"
      },
      {
        "domain_suffix": [
          "voidboost.one"
        ],
        "domain_regex": [
          "(^|\\.)voidboost\\.[a-z0-9-]+$"
        ],
        "outbound": "direct"
      },
      {
        "rule_set": [
          "manual-d"
        ],
        "outbound": "direct"
      },
      {
        "rule_set": [
          "ads-all"
        ],
        "outbound": "block"
      },
      {
        "rule_set": [
          "manual-t-priority",
          "manual-google-ai",
          "manual-t",
          "openai",
          "anthropic",
          "ai-not-cn",
          "youtube",
          "spotify",
          "lastfm",
          "facebook",
          "instagram",
          "whatsapp",
          "twitter",
          "telegram",
          "tiktok",
          "discord",
          "linkedin",
          "microsoft",
          "google",
          "wikimedia",
          "bbc",
          "cnn",
          "kinopub",
          "manual-t-late"
        ],
        "outbound": "tt-t"
      },
      {
        "rule_set": [
          "manual-a",
          "netflix",
          "hulu",
          "disney",
          "hbo",
          "espn",
          "primevideo"
        ],
        "outbound": "tt-a"
      }
    ],
    "final": "direct",
    "auto_detect_interface": false
  }
}
