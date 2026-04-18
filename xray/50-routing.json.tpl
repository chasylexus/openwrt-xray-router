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
        "domain": ["geosite:category-ru"],
        "outboundTag": "D"
      },

      {
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
          "geosite:apple",
          "domain:icloud.com",
          "domain:icloud-content.com",
          "domain:apple-cloudkit.com",
          "domain:mzstatic.com",
          "full:captive.apple.com",
          "full:connectivitycheck.gstatic.com",
          "full:detectportal.firefox.com",
          "full:msftconnecttest.com",
          "full:nmcheck.gnome.org",
          "domain:kvk.com"
        ],
        "outboundTag": "D"
      },

      {
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
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
          "full:apis.google.com",
          "full:clients6.google.com",
          "full:colab.research.google.com",
          "full:geller-pa.googleapis.com",
          "full:aida.googleapis.com",
          "full:aisandbox-pa.googleapis.com",
          "full:proactivebackend-pa.googleapis.com",
          "full:robinfrontend-pa.googleapis.com",
          "full:antigravity-pa.googleapis.com",
          "full:antigravity.googleapis.com",
          "domain:antigravity.google",
          "full:stitch.withgoogle.com",
          "full:firebaseinstallations.googleapis.com",
          "full:speechs3proto2-pa.googleapis.com"
        ],
        "outboundTag": "A"
      },
      {
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
          "geosite:openai",
          "geosite:anthropic",
          "geosite:category-ai-!cn",
          "domain:openai.com",
          "domain:chatgpt.com",
          "domain:oaistatic.com",
          "domain:oaiusercontent.com",
          "domain:sora.com",
          "domain:anthropic.com",
          "domain:claude.ai",
          "domain:claude.com",
          "domain:claudeusercontent.com",
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
          "domain:dify.ai",
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
        "outboundTag": "A"
      },
      {
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
          "geosite:netflix",
          "geosite:spotify",
          "geosite:amazon",
          "domain:walmart.com",
          "domain:ikea.com.tr",
          "domain:onfastspring.com",
          "domain:paytr.com",
          "domain:stripe.com",
          "domain:blockchain.com",
          "domain:sentry.io",
          "domain:datadoghq.com",
          "domain:branch.io",
          "domain:stytch.com",
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
        "outboundTag": "A"
      },

      {
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": ["geosite:telegram"],
        "outboundTag": "T"
      },
      {
        "type": "field",
        "inboundTag": ["c-def-in"],
        "ip": ["geoip:telegram"],
        "outboundTag": "T"
      },

      {
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
          "geosite:youtube",
          "geosite:google",
          "geosite:facebook",
          "geosite:instagram",
          "geosite:twitter",
          "geosite:tiktok",
          "geosite:discord",
          "geosite:linkedin",
          "geosite:microsoft",
          "geosite:wikimedia",
          "geosite:bbc",
          "geosite:cnn",
          "geosite:category-porn"
        ],
        "outboundTag": "T"
      },
      {
        "type": "field",
        "inboundTag": ["c-def-in"],
        "domain": [
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
          "domain:kino.pub",
          "domain:kinopub.online",
          "domain:kinogo.biz",
          "domain:ottclub.tv",
          "domain:dailymail.co.uk",
          "domain:cosmopolitan.com",
          "domain:evonomics.com",
          "domain:flipboard.com",
          "domain:medium.com",
          "domain:penguinrandomhouse.com",
          "domain:wtfhappenedin1971.com",
          "domain:proton.me",
          "domain:protonmail.com",
          "domain:amnezia.org",
          "domain:tunnelbear.com",
          "domain:redshieldvpn.com",
          "domain:peacocktv.com",
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
        "type": "field",
        "inboundTag": ["c-def-in"],
        "outboundTag": "D"
      }
    ]
  }
}
