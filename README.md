# openwrt-xray-router

Production-grade setup for an OpenWrt router with dual-circuit policy routing via Xray:
separate handling for the router itself (OUTPUT hook) and for LAN clients (PREROUTING hook),
with fallback through Xray routing by domain / geosite / geoip.

Designed for set-and-forget deployment: safe bootstrap ensure → optional `--force-init` → cron → atomic updates → rollback on any validation error.

`REPO_RAW` in this README means the base raw URL from which the router fetches repo-tracked files. The built-in default is:

```text
https://raw.githubusercontent.com/chasylexus/openwrt-xray-router/refs/heads/main
```

Bootstrap uses `REPO_RAW` to fetch only repo-tracked files: helper scripts, templates, starter lists, and `secret.env.example`.

## Platform

- OpenWrt 25.12.2 (r32802+), BusyBox ash v1.37+
- Package manager: **apk** (not opkg)
- Xray already installed as a binary at `/usr/local/xray/xray`
- Xray assets (`geosite.dat`, `geoip.dat`) at `/usr/local/xray/`
- dnsmasq-full with nftset support

## Dependencies

Required (checked by `bootstrap-xray-v2.sh`):
- `ash`, `awk`, `sed`, `grep`, `sort`, `uniq`
- `nft` (nftables)
- `ip` (iproute2)
- `nslookup`
- `wget` **or** `curl` (one is enough)
- `uci`
- `procd` / `service`

Intentionally **not** used: `jq`, `python`, `perl`, `opkg`.

## Architecture overview

### Two circuits

**Circuit 1: the router itself (OUTPUT).**
`nft table inet xray_router` holds sets `r_T_v4`, `r_A_v4`.
If `daddr` matches a set — `redirect to :10801` (→ `r-T-in` → outbound T)
or `:10802` (→ `r-A-in` → outbound A). Everything else goes direct (system path).

**Circuit 2: LAN clients (PREROUTING on `br-lan`).**
`nft table inet xray_clients` holds sets `c_D_v4`, `c_T_v4`, `c_A_v4`.
- `c_D_v4` → `return` (direct, no Xray hop).
- `c_T_v4` → `redirect to :10811` (→ `c-T-in` → outbound T).
- `c_A_v4` → `redirect to :10812` (→ `c-A-in` → outbound A).
- Default TCP → `redirect to :10813` (→ `c-def-in` → Xray routing by rules).

### Fallback (`c-def-in`)

Xray routing for inbound `c-def-in` is evaluated top to bottom (first match wins).
The concrete service-to-outbound mapping changes over time and is intentionally
**not** duplicated in this README.

Source of truth:

- [xray/50-routing.json.tpl](./xray/50-routing.json.tpl) — ordered routing rules
- [lists/](./lists/) — static repo-managed list inputs

Stable high-level shape:

1. safety / captive-portal / direct-only exceptions
2. ad blocking
3. explicit service-family overrides (for example AI, streaming, big social)
4. targeted IP fallbacks where domain routing cannot help
5. final catch-all direct fallback

Specific rules (for example a narrow subdomain override above a broad geosite)
must stay above broader matches because xray evaluates rules in order. The nft
layer cannot express that priority — it only sees resolved IPs.

### Anti-loop

Xray outbounds T/A/D set `sockopt.mark = 0xff` on outgoing sockets.
First rule in both nft tables: `meta mark 0xff return`. That is sufficient.
No uid/pid matching is used — it is fragile.

## Naming scheme (fixed)

### Outbounds
- `T` — proxy outbound 1 (VLESS + Reality)
- `A` — proxy outbound 2 (VLESS + Reality)
- `D` — direct (freedom)
- `B` — block (blackhole)

### Inbounds
- `r-T-in` — 10801, dokodemo-door, routed → `T`
- `r-A-in` — 10802, dokodemo-door, routed → `A`
- `c-D-in` — 10810, dokodemo-door, routed → `D` *(exists, but not used by base nft — see below)*
- `c-T-in` — 10811, dokodemo-door, routed → `T`
- `c-A-in` — 10812, dokodemo-door, routed → `A`
- `c-def-in` — 10813, dokodemo-door, routed by rules

### nft sets
- Router: `r_T_v4`, `r_A_v4`
- Clients: `c_D_v4`, `c_T_v4`, `c_A_v4`

### Lists
- `r-T-ipv4.txt`, `r-A-ipv4.txt`
- `r-T-domains.txt`, `r-A-domains.txt`
- `c-D-ipv4.txt`, `c-T-ipv4.txt`, `c-A-ipv4.txt`
- `c-D-domains.txt`, `c-T-domains.txt`, `c-A-domains.txt`

## File layout on the router

```
/etc/xray/
├── secret.env                  # LOCAL, git-ignored, never committed
├── config.d/                   # rendered Xray JSON (read by xray -confdir)
│   ├── 00-base.json
│   ├── 10-inbounds.json
│   ├── 20-outbounds.json
│   └── 50-routing.json
├── nft.d/                      # rendered nft rules
│   ├── 10-router-output.nft
│   └── 20-clients-prerouting.nft
├── lists/
│   ├── local/                  # manually maintained lists
│   ├── remote/                 # downloaded remote lists
│   └── merged/                 # merge + resolve result (IPv4)
├── templates/                  # cached downloaded templates
├── state/                      # timestamps, success flags
├── bin/                        # helper scripts (copies from repo)
└── dnsmasq.d/
    └── 90-nftset.conf          # RAW snippet for dnsmasq confdir

/usr/local/xray/xray            # existing binary
/usr/local/xray/geosite.dat
/usr/local/xray/geoip.dat

/etc/init.d/xray                # SINGLE start point
/etc/dnsmasq.d/90-nftset.conf   # symlink to /etc/xray/dnsmasq.d/90-nftset.conf
```

### Why `xray -confdir`

`xray run -confdir /etc/xray/config.d` reads all `.json` files in alphabetical order and merges them. This allows splitting base config, inbounds, outbounds, and routing — convenient for separate updates and for rendering secrets (outbounds) independently from public templates.

## What is edited locally (NOT committed)

1. `/etc/xray/secret.env` — main secrets file. Format: shell env-file, safe for `. secret.env`. Contains template URLs, list URLs, asset URLs, and either full `T_VLESS_URL` / `A_VLESS_URL` share links or split UUID/PBK/SID/SNI/HOST/PORT/fingerprint fields for T and A.
2. `/etc/xray/lists/local/*.txt` — your local domain/IP lists that supplement (or fully replace) remote ones.

## What is hosted on GitHub

1. All templates (`xray/*.json.tpl`, `nft/*.nft.tpl`, `dnsmasq/*.conf.tpl`).
2. All helper scripts (`bin/*.sh`).
3. Bootstrap (`bootstrap/bootstrap-xray-v2.sh`).
4. init.d service (`init.d/xray`).
5. Starter lists (`lists/*.txt`) — examples only, NOT with real sensitive policy.
6. Example file `examples/secret.env.example`.

Secrets never go to GitHub. `.gitignore` covers `secret.env` as a safeguard.

### Repo-managed nft-stage IP lists

`c-T-dst-v4.txt` and `c-A-dst-v4.txt` are special: they feed the nft
`c_T_dst_v4` / `c_A_dst_v4` sets directly, so the packet is bound to outbound
`T` or `A` at the nft stage before `c-def-in` reaches xray domain routing.

If `LISTS_C_T_DST_V4_URL` / `LISTS_C_A_DST_V4_URL` are left unset and
`REPO_RAW` is pinned, `fetch-remote-lists.sh` defaults them to:

- `$REPO_RAW/lists/c-T-dst-v4.txt`
- `$REPO_RAW/lists/c-A-dst-v4.txt`

That enables the workflow: edit IP/CIDR lists in GitHub -> push -> router cron
pulls from raw GitHub -> `update-sets.sh` safely rebuilds nft sets. Set a var
to an explicit empty string to disable the repo-managed default for that file.

## First run (end-to-end)

### 1. Fork the repository and edit lists for your needs

You can also start with the default examples.

### 2. On a new router, as root

Preferred path for a fresh router:

```sh
BOOTSTRAP_URL='https://raw.githubusercontent.com/chasylexus/openwrt-xray-router/refs/heads/main/bootstrap/bootstrap-xray-v2.sh'
uclient-fetch -O /tmp/bootstrap.sh "$BOOTSTRAP_URL" \
  || wget -O /tmp/bootstrap.sh "$BOOTSTRAP_URL"
sh /tmp/bootstrap.sh --force-init
```

That path is intentionally split in two network phases:
- Phase 1 uses `REPO_RAW` first. bootstrap pulls repo files, can prompt for `T_VLESS_URL` / `A_VLESS_URL`, writes `secret.env`, and prepares the managed stack.
- Phase 2 touches OpenWrt package feeds only when needed. If the router already has the critical pre-route tools (`nft`, `ip`, `uci`, `xray`, downloader), bootstrap defers package feeds until after routing is up. If one of those critical pieces is missing, feed access becomes unavoidable before routing.

### 3. On the router, as root:

```sh
# uses built-in REPO_RAW unless you pass an explicit override URL
BOOTSTRAP_URL='https://raw.githubusercontent.com/chasylexus/openwrt-xray-router/refs/heads/main/bootstrap/bootstrap-xray-v2.sh'
wget -O /tmp/bootstrap.sh "$BOOTSTRAP_URL"
sh /tmp/bootstrap.sh
```

If you ever need to point the router at a different repo/branch temporarily, you can still pass an explicit override:

```sh
wget -O /tmp/bootstrap.sh 'https://raw.githubusercontent.com/chasylexus/openwrt-xray-router/refs/heads/main/bootstrap/bootstrap-xray-v2.sh'
sh /tmp/bootstrap.sh --force-init 'https://raw.githubusercontent.com/<owner>/<repo>/refs/heads/<branch>'
```

In interactive mode bootstrap asks only for:
- `T_VLESS_URL` and `A_VLESS_URL` with neutral examples
- pressing Enter on `A_VLESS_URL` reuses `T_VLESS_URL`

Bootstrap will:
- create `/etc/xray/{config.d,nft.d,lists/{local,remote,merged},templates,state,bin,dnsmasq.d}`;
- download helper scripts to `/etc/xray/bin/`;
- install `/etc/init.d/xray`;
- install the managed Xray cron block when that is safe;
- if interactive and `secret.env` is missing/incomplete — offer to create/fill it with `T_VLESS_URL` / `A_VLESS_URL`;
- prefer `REPO_RAW` downloads first and postpone OpenWrt package feeds until the last responsible moment;
- **not** force-render or restart Xray in default ensure mode;
- if `secret.env` is absent — place `/etc/xray/secret.env.example` alongside it and print instructions.

### 4. Bootstrap modes

- Default mode is safe `ensure`: refresh managed files, keep local secrets/lists, install the managed cron block when that does not conflict with legacy cron lines, and stop there.
- `--force-init` is the "make it ready" mode: after the same safe bootstrap steps it installs only the critical missing pre-route packages if they are absent, runs `update-all.sh`, enables `xray`, starts it, and only then installs/verifies the remaining post-route packages such as `dnsmasq-full`.
- If legacy `/etc/xray/bin/...` cron lines exist outside the managed block, default mode warns and leaves them alone; `--force-init` migrates them into the managed block automatically.

### 5. Create `/etc/xray/secret.env`

```sh
cp /etc/xray/secret.env.example /etc/xray/secret.env
vi /etc/xray/secret.env
chmod 600 /etc/xray/secret.env
```

Fill in the URLs and T/A connection details.

You can either:
- paste full `T_VLESS_URL` / `A_VLESS_URL` links, or
- keep using split `T_HOST`, `T_PORT`, `T_UUID`, `T_SNI`, `T_FP`, `T_PBK`, `T_SID` and the matching `A_*` variables.

When a `*_VLESS_URL` variable is set, it takes precedence. The parser is intentionally strict and only accepts the VLESS+Reality-over-TCP shape that this repo renders; unsupported share links fail closed instead of producing a half-wrong config.

### 6. First managed-apply

Once `secret.env` is filled, the preferred one-shot path is:

```sh
sh /tmp/bootstrap.sh --force-init
```

That reruns the safe bootstrap steps, migrates/install the managed cron block, performs the full staged apply chain, and starts `xray` if needed.

Manual apply still works too:

```sh
/etc/xray/bin/update-all.sh
```

`update-all.sh` runs the full manual refresh chain in order:
1. `update-managed-stack.sh`
2. `update-sets.sh` (prime the live nft sets after `apply-nft` recreates them)
3. wait for the router-side T inbound to start listening again after reload
4. `update-assets.sh`
5. `fetch-remote-lists.sh`
6. `fetch-allow-domains.sh`
7. `update-sets.sh` (final pass so live sets match the freshly downloaded lists)

Each step must finish with `OK` and must not touch working state on error.

If you want to debug a specific layer separately, the original manual sequence
still works:

```sh
/etc/xray/bin/update-managed-stack.sh
/etc/xray/bin/fetch-remote-lists.sh
/etc/xray/bin/update-sets.sh
```

### 7. Start

```sh
/etc/init.d/xray enable
/etc/init.d/xray start
```

### 8. Verify

```sh
# Xray is alive
pidof xray
logread -e xray | tail -40

# nft tables are present
nft list table inet xray_router | head -40
nft list table inet xray_clients | head -40

# sets are populated
nft list set inet xray_router r_T_v4 | head
nft list set inet xray_clients c_T_v4 | head

# router exits via T for an address from r_T_v4
curl -s -m 5 https://ifconfig.me

# LAN client:
curl -s https://ifconfig.me
```

## Custom geosite (optional)

In addition to the standard upstream `geosite.dat`, you can load a second geosite file and reference its tags in routing rules.

1. Set `GEOSITE_CUSTOM_URL` in `/etc/xray/secret.env` to the raw URL of a `.dat` file. Empty = disabled.
2. `update-assets.sh` downloads it to `/usr/local/xray/geosite-custom.dat`, validates the whole asset set via `xray -test`, then atomically replaces the live file. On any error the previous file is retained.
3. Reference tags in routing rules as `ext:geosite-custom.dat:<tag>`, for example:
   ```json
   {
     "type": "field",
     "inboundTag": ["c-def-in"],
     "domain": ["ext:geosite-custom.dat:my-work"],
     "outboundTag": "A"
   }
   ```
   Place such rules either in `xray/50-routing.json.tpl` (shared, committed to the repo) or in a router-local file like `/etc/xray/config.d/99-local.json` (not overwritten by `update-managed-stack.sh`).

Cron updates the custom file on the same schedule as `geosite.dat` / `geoip.dat`.

## Allow-domains provider (optional)

A third source of domain lists is supported alongside `local/` and `remote/`: a curated provider reachable at a private base URL.

1. Set `ALLOW_DOMAINS_BASE` in `/etc/xray/secret.env` to the provider's base URL. Leave empty to disable.
2. Path suffixes are hardcoded in `bin/fetch-allow-domains.sh` (the `ITEMS` table) so the upstream identity stays out of the committed repo. Edit that table to add or remove mappings. Defaults:
   - `Russia/inside-raw.lst` → `c-T-domains.txt`
3. Downloaded files land at `/etc/xray/lists/remote/allow-<name>.txt` and are unioned into the merged list by `merge-lists.sh` alongside `local/` and `remote/`.
4. Cron runs `fetch-allow-domains.sh` every 6 hours; it is a silent no-op when `ALLOW_DOMAINS_BASE` is empty.

## Rule ordering

At both the nft and xray layers, A rules are evaluated before T rules. When a destination IP appears in both `c_A_v4`/`r_A_v4` and `c_T_v4`/`r_T_v4` (e.g. Gemini vs Google overlap on the same Google edge IPs), A wins. Domain-level disambiguation for the fallback `c-def-in` inbound is handled inside `xray/50-routing.json.tpl` where specific domains (gemini, netflix, ...) are matched before generic geosite tags.

## How to update

Everything is orchestrated by cron. bootstrap installs the managed block automatically (reference copy: `examples/crontab.example`):

- `update-assets.sh` — weekly: update `geosite.dat` / `geoip.dat` / `geosite-custom.dat` (if `GEOSITE_CUSTOM_URL` is set) from `GEOSITE_URL` / `GEOIP_URL` / `GEOSITE_CUSTOM_URL`.
- `update-managed-stack.sh` — daily: update Xray/nft templates and managed helper scripts from `REPO_RAW`.
- `fetch-remote-lists.sh` — every few hours: download remote lists.
- `fetch-allow-domains.sh` — every 6 hours: download allow-domains provider lists (no-op if `ALLOW_DOMAINS_BASE` is empty).
- `update-sets.sh` — every 15–30 minutes: merge lists + resolve domains + atomic replace set content.
- `cap-volatile-logs.sh` — every 10 minutes: trim `/tmp/xray-*.log` and `/tmp/xray-cron.log` in place to bounded size.

For a manual "update everything now" run outside cron, use:

```sh
/etc/xray/bin/update-all.sh
```

It intentionally chains the slow/rare and fast/frequent layers so you do not
end up in an intermediate state where Xray templates are new but nft sets are
still based on older list content.

All scripts are **staged/atomic**:
1. Download to temp files.
2. Render/resolve to `.staged`.
3. Validate: `xray -test`, `nft -c -f`, non-empty result.
4. Only on success — `mv` into place and soft reload.

On any error — exit 1 + remove temp files, working state is unchanged.

## Rollback

1. **Single bad update.** `/etc/xray/state/` holds `last-good-*.tar.gz` — snapshots of successfully applied configs (templates / config.d / nft.d). Manual restore:
   ```sh
   cd /
   tar xzf /etc/xray/state/last-good-managed.tar.gz
   /etc/init.d/xray reload
   ```

2. **Bad lists.** `update-sets.sh` snapshots current set elements before replacing — in `/etc/xray/state/last-good-sets.txt`. Restore:
   ```sh
   /etc/xray/bin/update-sets.sh --restore
   ```

3. **Nuclear option.** `/etc/init.d/xray stop && /etc/init.d/xray disable`. nft tables and ip rules are torn down in `stop_service`. The router keeps working with normal system routing.

## Debugging

```sh
# what xray is doing
logread -e xray | tail -200

# live nft
nft monitor

# rule counters
nft list ruleset | grep -E 'xray_(router|clients)|counter'

# actual set contents
nft list set inet xray_clients c_T_v4

# trace update-sets resolution
sh -x /etc/xray/bin/update-sets.sh

# test any template render
/etc/xray/bin/render-template.sh /etc/xray/templates/xray/20-outbounds.json.tpl
```

## Critical path vs. optional

**Critical path (must work):**
1. `update-sets.sh` (merge + resolve + atomic nft element update)
2. `nft` rules (`10-router-output.nft`, `20-clients-prerouting.nft`)
3. Xray with a valid `config.d`

**Optional bonus layers (if broken — the base setup still works):**
- `dnsmasq/90-nftset.conf` (lazy DNS-driven set filling)
- `update-managed-stack.sh` (if GitHub is unavailable — continue with local templates)
- `update-assets.sh` (if geosite/geoip did not update — use the previous ones)

## Design decisions & tradeoffs

These are intentional tradeoffs within the requested architecture.

1. **TCP-only in nft redirect.** Uses `redirect to :port` — this is DNAT, which works for TCP. UDP (including QUIC-443) is **not** intercepted in the base setup and goes direct. UDP requires TPROXY with `meta mark` and `ip rule fwmark lookup`, which adds complexity. The TPROXY option is left as a clearly marked TODO in `nft/20-clients-prerouting.nft.tpl`. Most HTTPS sites fall back to TCP+TLS when QUIC is unavailable — TCP-only is sufficient for most practical cases. Tradeoff: simplicity > completeness.

2. **`c-D-in` exists but is not used by nft by default.** This lets you explicitly route traffic through Xray with D-outbound (for logging / single sniffing point), but in the base critical path we do `return` in nft for `c_D_v4` — one hop fewer.

3. **Anti-loop via `sockopt.mark = 0xff`.** We do not bind to Xray's uid because in OpenWrt procd, Xray may run under an unstable uid, which breaks idempotency. mark 0xff on Xray outgoing sockets via `streamSettings.sockopt.mark` is the most direct and portable approach.

4. **4 separate Xray JSON files via `-confdir`.** This allows:
   - updating publicly-hostable templates separately from `20-outbounds.json` which holds secrets;
   - restoring only the needed file during rollback.

5. **dnsmasq via raw confdir snippet, not UCI `list nftset`.** The UCI approach does not work reliably on this OpenWrt build. We place the file in `/etc/dnsmasq.d/` (OpenWrt dnsmasq confdir) as a symlink from `/etc/xray/dnsmasq.d/90-nftset.conf`, so the renderer can rebuild it independently.

6. **POSIX-only templating.** `render-template.sh` uses `sed` with `s|__VAR__|$VALUE|g` on a known list of placeholders. No eval on data, no `envsubst` (sometimes not installed), no `sh -c` with user-supplied values — protection against injection via secret.env.

7. **Lists are plain text.** One host per line, `#` starts a comment. `awk`/`sort`/`uniq` do the rest. No YAML/JSON — nothing to parse complex structures from.

8. **Lightweight rollback snapshots.** `tar czf` on `config.d` + `nft.d` takes negligible space; the last 5 are retained.

## Verifying everything works

```sh
# 1. Xray service up
/etc/init.d/xray status           # prints PID

# 2. Xray listen ports
netstat -lntp | grep -E ':1080[01]|1081[0-3]'
# expected: 10801, 10802, 10810, 10811, 10812, 10813

# 3. nft tables
nft list tables | grep -E 'xray_(router|clients)'
# both should be present

# 4. sets non-empty (after update-sets)
nft list set inet xray_router r_T_v4 | grep -c '^\s*[0-9]'
nft list set inet xray_clients c_T_v4 | grep -c '^\s*[0-9]'
# > 0

# 5. Router E2E: take an IP from r-T-ipv4.txt, add to /etc/hosts,
#    run curl -s https://ifconfig.me — the outgoing IP should change

# 6. LAN client E2E: from a LAN client run curl https://ifconfig.me
#    for addresses in c_T_v4 — exits via T; in c_A_v4 — via A; direct — your ISP

# 7. No loop
nft list ruleset | grep -E 'mark 0xff.*return'
# should be exactly two lines (router + clients)

# 8. dnsmasq fill (optional)
dig @127.0.0.1 google.com
nft list set inet xray_clients c_T_v4   # a freshly resolved IP should appear
```

## License

See `LICENSE`. MIT.
