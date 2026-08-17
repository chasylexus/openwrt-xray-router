# openwrt-xray-router

This repository now describes the router stack built around TrustTunnel and
sing-box. The old Xray-based stack is preserved under
[`legacy/xray-v2/`](./legacy/xray-v2/) as a rollback/reference copy.

No real endpoint credentials belong in this repository. Filled local files stay
on the router only.

## Active Architecture

Traffic from LAN clients and from the router itself is captured by a sing-box
TUN inbound. sing-box decides whether a request stays on the direct router path
or goes to the local TrustTunnel SOCKS listener.

```text
LAN clients / router
  -> sing-box TUN policy router
     -> direct
     -> tt-t -> 127.0.0.1:11080
     -> tt-a -> 127.0.0.1:11080
          -> TrustTunnel client
```

`tt-t` and `tt-a` are intentionally separate route labels in GitHub, even when
both currently point to the same local TrustTunnel client. That keeps the rule
model stable if the two paths later diverge.

Tailscale has a dedicated localhost HTTP CONNECT inbound:

```text
tailscaled -> 127.0.0.1:10810
           -> tailscale-underlay selector
              -> tt-t (preferred)
              -> direct (watchdog fallback)
```

The selector API listens only on `127.0.0.1:9090`. A procd watchdog verifies
real HTTPS through TrustTunnel, switches to `direct` after three consecutive
failures, and returns to `tt-t` after two successful checks. Tailscale
coordination and DERP domains from LAN clients use the same selector.
`100.64.0.0/10` and private IPv6 ranges stay excluded from the sing-box TUN.

Voidboost uses a separate selector so its player requests normally share the
same `tt-t` exit as Rezka. A dedicated watchdog probes the real Voidboost HTTPS
endpoint through TrustTunnel, falls back to `direct` after three consecutive
TLS failures, and returns to `tt-t` after two successful checks.

## Rule Sources

The manual rule source is supplied locally to bootstrap and is not pinned to a
personal account in this repository:

```text
REPLACE_WITH_RULESET_BASE
```

The router also uses ready-made sing-box rule sets from SagerNet
`sing-geosite`.

Last.fm uses SagerNet's `geosite-lastfm.srs` rule-set and routes through `tt-t`.

The active sing-box config sets `update_interval: "2h"` on every remote rule
set, so rule updates are handled by sing-box itself. There is no separate Xray
cron path in the active stack.

Current high-level routing:

- `manual-d` stays direct.
- `voidboost.*` uses `voidboost-egress`: `tt-t` preferred, `direct` fallback.
- `ads-all` is blocked.
- `manual-t-priority`, `manual-google-ai`, `manual-t`, `manual-t-late`, and the
  T-side ready-made lists go to `tt-t`.
- `manual-a` plus the A-side video lists go to `tt-a`.
- Final fallback is direct.

Apple TV+ is not included in the A-side video group.

## Active Files

```text
bootstrap/bootstrap-sing-box-router.sh
bootstrap/bootstrap-xray-v2.sh          # compatibility wrapper
sing-box-router/config.json.tpl
trusttunnel/router-client.toml.example
init.d/sing-box-router
init.d/trusttunnel-client
init.d/router-clock-bootstrap
init.d/tailscale
init.d/tailscale-underlay-watchdog
init.d/voidboost-egress-watchdog
bin/arm-router-rollback.sh
bin/confirm-router-cutover.sh
bin/rollback-to-legacy-xray.sh
bin/refresh-sing-box-rules.sh
bin/tailscale-underlay-watchdog.sh
bin/voidboost-egress-watchdog.sh
package/sing-box-router-bin/Makefile
tools/build-sing-box-router-bin.sh
```

On the router these become:

```text
/etc/sing-box-router/config.json
/etc/trusttunnel/router-client.toml
/etc/init.d/sing-box-router
/etc/init.d/trusttunnel-client
/etc/init.d/router-clock-bootstrap
/etc/init.d/tailscale
/etc/init.d/tailscale-underlay-watchdog
/etc/init.d/voidboost-egress-watchdog
/root/bin/rollback-to-legacy-xray.sh
/root/bin/refresh-sing-box-rules.sh
/root/bin/tailscale-underlay-watchdog.sh
/root/bin/voidboost-egress-watchdog.sh
```

## Bootstrap

Run on an OpenWrt router that uses `apk`:

```sh
REPO_RAW="REPLACE_WITH_REPOSITORY_RAW_URL"
curl -4 -fsSL "$REPO_RAW/bootstrap/bootstrap-sing-box-router.sh" -o /tmp/bootstrap-sing-box-router.sh
sh /tmp/bootstrap-sing-box-router.sh --ensure \
  --repo-raw "$REPO_RAW" \
  --ruleset-base REPLACE_WITH_RULESET_BASE \
  --tt-endpoint-ip REPLACE_WITH_TT_ENDPOINT_IPV4
```

If the TrustTunnel client binary is not already at
`/opt/trusttunnel/trusttunnel_client`, either place it there manually or run
bootstrap with a local/private download URL:

```sh
TT_CLIENT_URL="REPLACE_WITH_LOCAL_TT_CLIENT_BINARY_URL" sh /tmp/bootstrap-sing-box-router.sh --ensure --tt-endpoint-ip REPLACE_WITH_TT_ENDPOINT_IPV4
```

Then edit only the local router file:

```sh
vi /etc/trusttunnel/router-client.toml
chmod 600 /etc/trusttunnel/router-client.toml
```

Fill every `REPLACE_WITH_*` value in that file. Do not paste those values into
chat, issues, commits, logs, or README files.

The TrustTunnel template uses an ad-blocking DoH upstream:

```toml
dns_upstreams = ["https://dns.adguard-dns.com/dns-query"]
```

That line appears both at the top level and inside `[endpoint]`. Streaming
provider proxy detection is handled by the reputation of the selected exit IP;
do not treat the TrustTunnel DoH setting as the control plane for that.

Keep `upstream_protocol` unchanged. This client build rejected `"https"` and
`"doh"` as protocol values during live testing, while the DoH URL in
`dns_upstreams` worked.

After the local file is filled:

```sh
sh /tmp/bootstrap-sing-box-router.sh --apply --tt-endpoint-ip REPLACE_WITH_TT_ENDPOINT_IPV4
```

`--ensure` installs and renders files without switching traffic. `--apply`
checks sing-box, configures the firewall, starts TrustTunnel, disables the old
stack if present, starts the active sing-box router service, and switches DNS
only after the service health check passes.

To force an immediate refresh of every remote rule-set without deleting
sing-box's fake-IP mappings:

```sh
sh /root/bin/bootstrap-sing-box-router.sh --refresh-rules
```

The refresh path validates and runs a temporary configuration from an isolated
staging directory; it never replaces the active `config.json`. Dnsmasq stays
up, while managed sing-box is stopped briefly to snapshot `cache.db`. Remote
rule-sets are refreshed sequentially in staging, with only the current target
using a one-second interval, so the proxy is not hit by dozens of simultaneous
TLS downloads. A detached supervisor gives each staging process a hard timeout
even if the calling shell disappears. The script waits for a successful update
or not-modified response for every remote rule-set, then starts the managed
service, verifies the DNS and test listeners, and restarts dnsmasq. Any failure
restores the cache snapshot; a reboot always starts with the untouched normal
config.

During cutover, a short rollback timer is armed before the legacy stack is
stopped and is disarmed only after DNS has switched successfully.

Before TrustTunnel starts at boot, `router-clock-bootstrap` resolves the
configured NTP pool through the WAN-provided DNS server directly and runs a
one-shot NTP sync against the resulting IPv4 addresses. This avoids a boot
dependency loop between correct TLS time, TrustTunnel, sing-box DNS, and the
normal `sysntpd` service.

## Local Safety

The bootstrap creates timestamped backups under:

```text
/root/router-stack-backups/YYYYMMDD-HHMMSS/
```

Sensitive local config files are written mode `600`. The TrustTunnel SOCKS
listener and the sing-box test listener are localhost-only:

```text
127.0.0.1:11080
127.0.0.1:10809
```

No external SOCKS or mixed proxy port is opened by this repo.

Because this router does not terminate or forward IPsec, the bootstrap removes
the stock `Allow-IPSec-ESP` and `Allow-ISAKMP` WAN-to-LAN exceptions.
It also disables the package-provided `sing-box` boot service and normalizes
the Tailscale boot link so only the repo-managed services start.

The Tailscale proxy, selector API, DNS listener, and test proxy are also
localhost-only:

```text
127.0.0.1:10810
127.0.0.1:9090
127.0.0.1:1053
127.0.0.1:10809
```

For a nested-router home setup, `/root/bin/configure-local-router-access.sh`
can be run manually after bootstrap to make local operations safer:

```sh
UPSTREAM_SSH_CIDR="REPLACE_WITH_UPSTREAM_PRIVATE_CIDR" \
LAN_SSH_CIDR="REPLACE_WITH_LAN_PRIVATE_CIDR" \
sh /root/bin/configure-local-router-access.sh
```

It backs up `/etc/config/firewall`, `/etc/config/dropbear`, and
`/etc/config/network`, opens SSH only from those private source ranges, and
enables STP on `br-lan`. It does not store credentials or TrustTunnel config.

## Persistence

The active services must be enabled in OpenWrt init:

```sh
/etc/init.d/trusttunnel-client enabled
/etc/init.d/sing-box-router enabled
/etc/init.d/router-clock-bootstrap enabled
/etc/init.d/tailscale-underlay-watchdog enabled
/etc/init.d/voidboost-egress-watchdog enabled
/etc/init.d/tailscale enabled
```

The bootstrap configures Tailscale's `HTTP_PROXY` and `HTTPS_PROXY` through
UCI and enables `TS_DEBUG_ALWAYS_USE_DERP=true`. Forced DERP hides direct peer
addresses from the local access provider, at the cost of relay latency and
throughput. The setting is a Tailscale debug env knob rather than a stable
public API; disable it with
`uci set tailscale.settings.always_use_derp=0 && uci commit tailscale` if a
future Tailscale release removes it.

The TrustTunnel DNS settings are persistent because they live in:

```text
/etc/trusttunnel/router-client.toml
```

The generated sing-box config is persistent at:

```text
/etc/sing-box-router/config.json
```

The pinned `sing-box` release can also be built as the personal
`sing-box-router-bin` APK. It owns only `/usr/local/bin/sing-box`; installing it
does not modify the active configuration or restart the service. Build and
upgrade notes are in
[`package/sing-box-router-bin/README.md`](./package/sing-box-router-bin/README.md).

Both the package and the bootstrap add the binary to `/etc/sysupgrade.conf`.
This is intentional: the public OpenWrt Sysupgrade Server cannot fetch a
package that exists only in this repository. Before a public `owut` build,
exclude the local package name and verify the preserved file:

```sh
sysupgrade -l | grep -Fx /usr/local/bin/sing-box
owut check -V 25.12.5 -r sing-box-router-bin
```

The optional files under `server/systemd/` automate certificate renewal,
TrustTunnel certificate reloads, and the server-side T outbound health check.
They do not automate free No-IP hostname renewal or manual No-IP address
updates; those remain an external operator responsibility.

## Verification

On the router:

```sh
/usr/local/bin/sing-box -D /var/lib/sing-box-router -C /etc/sing-box-router check
/etc/init.d/trusttunnel-client status
/etc/init.d/sing-box-router status
/etc/init.d/router-clock-bootstrap enabled
/etc/init.d/tailscale-underlay-watchdog status
/etc/init.d/voidboost-egress-watchdog status
/etc/init.d/tailscale status
cat /tmp/router-clock-bootstrap.ok
ss -lntp | grep -E ':(11080|10809|10810|9090|1053)'
curl -fsS http://127.0.0.1:9090/proxies/tailscale-underlay
curl -fsS http://127.0.0.1:9090/proxies/voidboost-egress
tailscale status
ip link show sb-tun0
uci show firewall.singbox_tun
uci show firewall.lan_to_singbox_tun
uci show firewall | grep Allow-SSH-from
uci get network.@device[0].stp
cat /sys/class/net/br-lan/bridge/stp_state
```

Expected listener addresses are all `127.0.0.1` except the TUN interface.

Smoke tests:

```sh
curl -4 -fsS --connect-timeout 5 --max-time 12 https://ipinfo.io/country
curl -4 -I -fsS --connect-timeout 5 --max-time 15 https://www.netflix.com/
curl -4 -I -fsS --connect-timeout 5 --max-time 15 https://gemini.google.com/
curl -4 -sS -o /dev/null -w '%{http_code}\n' --socks5-hostname 127.0.0.1:11080 http://doubleclick.net/
```

The ad-domain SOCKS test is expected to fail or return a non-success code when
the ad-blocking DoH upstream is active.

Use temporary sing-box log level changes only during diagnostics, then return
to `warn`.

## Rollback

If the active stack is not healthy:

```sh
sh /root/bin/rollback-to-legacy-xray.sh
```

For a manual rollback, restore the previous files from
`/root/router-stack-backups/<timestamp>/`, restart `dnsmasq` and `firewall`,
stop `sing-box-router`, and re-enable the legacy service if that router still
uses it.
