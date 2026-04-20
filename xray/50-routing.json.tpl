{
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "domainMatcher": "hybrid",
    "rules": [
      {
        "_comment": "=== ROUTER-SIDE (nat/output) — explicit per-inbound binding ===",
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
        "_comment": "=== CLIENT-SIDE per-IP forced bindings (nft tproxy'd these) — no domain decision, outbound implicit by inbound ===",
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
        "_comment": "=== CLIENT-SIDE (c-def-in) — priority from most to least specific ===",
        "_comment_override_hint": "For per-device force-outbound, insert a rule ABOVE this block: { type: 'field', inboundTag: ['c-def-in'], source: ['192.168.1.50/32'], outboundTag: 'T' }. For per-device FULL bypass (skip xray), add the device IP to /etc/xray/lists/local/c-bypass-src-v4.txt — that's handled at nft level.",
        "_comment_1": "1. defense-in-depth: LAN/private never leaves via proxy",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "ip": ["geoip:private"],
        "outboundTag": "D"
      },

      {
        "_comment": "1b. captive portal probes — NEVER via proxy. Without these, geosite:google catches connectivitycheck.gstatic.com and geosite:microsoft catches msftconnecttest.com -> Android/Windows think there is no internet and drop/reconnect WiFi.",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
          "full:captive.apple.com",
          "full:connectivitycheck.gstatic.com",
          "full:connectivity-check.ubuntu.com",
          "full:detectportal.firefox.com",
          "full:msftconnecttest.com",
          "full:www.msftconnecttest.com",
          "full:www.msftncsi.com",
          "full:dns.msftncsi.com",
          "full:nmcheck.gnome.org",
          "full:network-test.debian.org"
        ],
        "outboundTag": "D"
      },

      {
        "_comment": "2. ads (optional — reject before they can go anywhere)",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "B"
      },

      {
        "_comment": "3a. Google AI -> A (itdoginfo GOOGLE-AI tag + explicit domains for coverage)",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
          "ext:geosite-custom.dat:GOOGLE-AI",
          "domain:gemini.google.com",
          "domain:bard.google.com",
          "domain:aistudio.google.com",
          "domain:generativelanguage.googleapis.com",
          "domain:makersuite.google.com",
          "domain:notebooklm.google.com",
          "domain:notebooklm.google",
          "domain:deepmind.com",
          "domain:deepmind.google",
          "domain:ai.google.dev",
          "domain:generativeai.google",
          "domain:labs.google",
          "domain:jules.google",
          "domain:antigravity.google",
          "full:apis.google.com",
          "full:clients6.google.com",
          "full:play.google.com",
          "full:colab.research.google.com",
          "full:geller-pa.googleapis.com",
          "full:aida.googleapis.com",
          "full:aisandbox-pa.googleapis.com",
          "full:proactivebackend-pa.googleapis.com",
          "full:robinfrontend-pa.googleapis.com",
          "full:antigravity-pa.googleapis.com",
          "full:antigravity.googleapis.com",
          "full:stitch.withgoogle.com",
          "full:firebaseinstallations.googleapis.com",
          "full:speechs3proto2-pa.googleapis.com"
        ],
        "outboundTag": "A"
      },

      {
        "_comment": "3b. streaming (Netflix / Peacock / Prime Video) -> A",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
          "geosite:netflix",
          "domain:primevideo.com",
          "domain:peacocktv.com"
        ],
        "outboundTag": "A"
      },

      {
        "_comment": "3c. IP geolocation / 'what is my IP' checks -> A (verify second exit independently)",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
          "domain:whatismyip.com"
        ],
        "outboundTag": "A"
      },

      {
        "_comment": "4a. OpenAI / ChatGPT -> T",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
          "geosite:openai",
          "domain:openai.com",
          "domain:chatgpt.com",
          "domain:oaistatic.com",
          "domain:oaiusercontent.com",
          "domain:sora.com"
        ],
        "outboundTag": "T"
      },

      {
        "_comment": "4b. Anthropic / Claude -> T",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
          "geosite:anthropic",
          "domain:anthropic.com",
          "domain:claude.ai",
          "domain:claude.com",
          "domain:claudeusercontent.com"
        ],
        "outboundTag": "T"
      },

      {
        "_comment": "4c. xAI / Grok / Microsoft Copilot / other AI -> T",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
          "geosite:category-ai-!cn",
          "domain:grok.com",
          "domain:x.ai",
          "full:copilot.microsoft.com",
          "domain:perplexity.ai",
          "domain:mistral.ai",
          "domain:cohere.ai",
          "domain:cohere.com",
          "domain:huggingface.co",
          "domain:together.ai",
          "domain:groq.com",
          "domain:replicate.com",
          "domain:openrouter.ai",
          "domain:fireworks.ai",
          "domain:cerebras.ai",
          "domain:poe.com",
          "domain:assemblyai.com",
          "domain:lightning.ai",
          "domain:monica.im",
          "domain:dify.ai"
        ],
        "outboundTag": "T"
      },

      {
        "_comment": "4d. AI Code / Design / Media / Infra -> T",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
          "domain:cursor.com",
          "domain:cursor.sh",
          "domain:v0.dev",
          "domain:lovable.dev",
          "domain:replit.com",
          "domain:bolt.new",
          "domain:midjourney.com",
          "domain:runway.ml",
          "domain:runwayml.com",
          "domain:elevenlabs.io",
          "domain:stability.ai",
          "domain:langchain.com",
          "domain:pinecone.io",
          "domain:weaviate.io",
          "domain:qdrant.tech"
        ],
        "outboundTag": "T"
      },

      {
        "_comment": "5a. Big social / media / search via geosite -> T",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
          "geosite:youtube",
          "geosite:spotify",
          "geosite:facebook",
          "geosite:instagram",
          "geosite:whatsapp",
          "domain:whatsapp.com",
          "domain:whatsapp.net",
          "domain:whatsapp.biz",
          "domain:bintray.com",
          "full:graph.facebook.com",
          "keyword:whatsapp",
          "geosite:twitter",
          "geosite:telegram",
          "geosite:tiktok",
          "geosite:discord",
          "geosite:linkedin",
          "geosite:microsoft",
          "geosite:google",
          "geosite:wikimedia",
          "geosite:bbc",
          "geosite:cnn"
        ],
        "outboundTag": "T"
      },

      {
        "_comment": "5b. Telegram MTProto DC IP ranges -> T. Mobile/desktop clients connect to datacenters by IP without DNS, so geosite:telegram (which is domain-only) does not catch them. These ranges are stable and not shared with CDNs, so an IP rule is safe.",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "ip": [
          "5.28.192.0/18",
          "91.105.192.0/23",
          "91.108.4.0/22",
          "91.108.8.0/21",
          "91.108.16.0/21",
          "91.108.56.0/22",
          "95.161.64.0/20",
          "149.154.160.0/20",
          "185.76.151.0/24"
        ],
        "outboundTag": "T"
      },

      {
        "_comment": "5c. WhatsApp IP ranges -> T. App connects to Meta DC by IP for media/push without DNS, so domain rules alone miss them.",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "ip": [
          "158.85.224.160/27",
          "158.85.46.128/27",
          "158.85.5.192/27",
          "173.192.222.160/27",
          "173.192.231.32/27",
          "208.43.122.128/27",
          "184.173.128.0/17",
          "50.22.198.204/30" #,
          # "18.194.0.0/15",
          # "34.224.0.0/12",
          # "54.242.0.0/15"
        ],
        "outboundTag": "T"
      },

      {
        "_comment": "6. RU blocked — media / torrents / sci / streaming / news -> T (itdoginfo HDREZKA tag + explicit domains/keywords)",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
          "ext:geosite-custom.dat:HDREZKA",
          "keyword:rutracker",
          "keyword:nnmclub",
          "keyword:nnm-club",
          "keyword:rezka",
          "keyword:speedtest",
          "keyword:ookla",
          "domain:habr.com",
          "domain:habrastorage.org",
          "domain:meduza.io",
          "domain:holod.media",
          "domain:svtv.org",
          "domain:wonderzine.com",
          "domain:rucriminal.info",
          "domain:bogmedia.org",
          "domain:rtfm.co.ua",
          "domain:4pda.to",
          "domain:4pda.ws",
          "domain:mywishlist.ru",
          "domain:libgen.li",
          "domain:library.lol",
          "domain:sci-hub.ru",
          "domain:sci-hub.se",
          "domain:hdrezka.ac",
          "domain:rezka.ag",
          "domain:voidboost.cc",
          "domain:filmix.ac",
          "geosite:kinopub",
          "domain:kinopub.me",
          "domain:service-kp.com",
          "domain:cdn32.lol",
          "domain:kinogo.biz",
          "domain:ottclub.tv",
          "domain:speedtest.net",
          "domain:ooklaserver.net",
          "domain:dailymail.co.uk",
          "domain:cosmopolitan.com",
          "domain:evonomics.com",
          "domain:flipboard.com",
          "domain:medium.com",
          "domain:penguinrandomhouse.com",
          "domain:wtfhappenedin1971.com",
          "domain:amnezia.org",
          "domain:proton.me",
          "domain:protonmail.com",
          "domain:tunnelbear.com",
          "domain:redshieldvpn.com",
          "domain:playstation.com",
          "domain:2ip.io",
          "domain:2ip.ru",
          "domain:whatismyipaddress.com",
          "domain:whatismyipaddress.info",
          "domain:1xbet.com"
        ],
        "outboundTag": "T"
      },

      {
        "_comment": "7. Dev tools / shopping / finance / monitoring / misc -> T",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
          "domain:jetbrains.com",
          "domain:stackoverflow.com",
          "domain:stackexchange.com",
          "domain:clickhouse.com",
          "domain:notion.so",
          "domain:canva.com",
          "domain:tableau.com",
          "domain:flourish.studio",
          "domain:zapier.com",
          "domain:zapier-deployment.com",
          "domain:setapp.com",
          "domain:softorino.com",
          "domain:meetingbar.app",
          "domain:radarr.video",
          "domain:jakeroid.com",
          "domain:technoplaza.net",
          "domain:tuxera.com",
          "domain:paragon-software.com",
          "domain:sentry.io",
          "domain:datadoghq.com",
          "domain:browser-intake-datadoghq.com",
          "domain:branch.io",
          "domain:stytch.com",
          "domain:ikea.com.tr",
          "domain:onfastspring.com",
          "domain:paytr.com",
          "domain:walmart.com",
          "domain:blockchain.com",
          "domain:stripe.com",
          "domain:hey.com",
          "domain:quora.com",
          "domain:coursera.org",
          "domain:patreon.com",
          "domain:fbi.gov",
          "domain:edgeuno.com",
          "domain:electronic.us",
          "domain:cdnst.net",
          "domain:ahrefs.com",
          "domain:baginya.org"
        ],
        "outboundTag": "T"
      },

      {
        "_comment": "7b. KinoPub Apple TV fallback IPs -> T. These are exact /32s observed from the Apple TV client when sniff/domain routing did not recover a match, so keep them narrow and revisit only if they stop appearing.",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "ip": [
          "104.21.12.188",
          "172.67.132.76"
        ],
        "outboundTag": "T"
      },

      {
        "_comment": "8. fallback: anything not matched above goes direct (home ISP)",
        "type": "field",
        "inboundTag": ["c-def-in"],
        "outboundTag": "D"
      }
    ]
  }
}
