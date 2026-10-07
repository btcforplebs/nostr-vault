# FIPS for Nostr Vault — Roadmap

**Goal: let friends reach your vault's relay and media directly, phone to phone or phone to Mac.
No public IP, no domain, no TLS certificate, no port forwarding, no VPN.**

*Rewritten 2026-10-07 for "v2", which is built on upstream `jmcorgan/fips` v0.5.2. The July
2026 version of this file planned everything around `fips-endpoint` (mmalmi's nvpn fork) and
said upstream FIPS could not be embedded in an app. Testing in September showed the opposite;
see "What changed" below.*

---

## 1. The short version

- Each vault runs a small FIPS mesh node inside the app. Your Nostr key is its address.
- Two vaults find each other by posting short signed messages on ordinary Nostr relays, then
  connect directly (UDP hole-punching with STUN). No middle server or "seed" node is needed.
- The vault's relay and Blossom media server already share one port, so one connection path
  carries both notes and media. The Go relay does not change.
- **Who can reach you is your choice.** Only friends on your list should be able to connect,
  and your phone should never carry strangers' traffic. That lock is not finished yet (§6),
  so "Share my relay" ships **off** by default until it is.

## 2. What changed since the July plan

| July plan said | What we found (Sep 2026) |
|---|---|
| Upstream `fips` is a system daemon and can't run inside an app. Use `fips-endpoint` instead. | Upstream v0.5.2 has `Node::enable_app_owned_tun()`. The app gets the raw packets itself, so no VPN or NetworkExtension is needed, on any platform. |
| Build a stream layer with QUIC (quinn) over FIPS datagrams. | Not needed. A small in-app TCP/IP stack (smoltcp) runs on those packets. Plain TCP, HTTP and WebSocket just work. |
| `fips-endpoint` (nvpn fork) is the way through. | The fork only sends connection offers over an *existing* FIPS route, so two phones behind home routers need a seed node to introduce them, and the public seeds dropped data. Upstream sends offers over plain Nostr relays. That is why v2 exists. |
| Datagram size, fragmentation and MTU budget were the main risk. | Those belonged to the QUIC design. With smoltcp, FIPS clamps TCP segment size itself. |

The old bridge (`fips-bridge/`, `FIPS_FFI_PLAN.md`, and Android PR #17) belongs to the July
design and is being retired.

## 3. How it fits together

```
Friend's app (reader)                                  Your app (sharer)
─────────────────────                                  ─────────────────
feed / images / video                                  Go relay + Blossom
   │ plain HTTP / WebSocket                               ▲ plain TCP
   ▼                                                      │
127.0.0.1:<port for your npub>                         127.0.0.1:<relay port>
   │                                                      ▲
smoltcp TCP  ──────── FIPS session (encrypted) ────────► smoltcp TCP
   │                                                      ▲
fips node ◄── find each other via Nostr relays + STUN ──► fips node
          ◄────────────── direct UDP link ─────────────►
```

- **Engine:** upstream `fips`, pinned to a tag (v0.5.2 today), plus smoltcp, in one Rust core
  shared by every platform. Code: `fips-v2/` (engine) and `fips-v2-android/` (Android wrapper).
- **Sharing:** the node accepts mesh connections on port 80 and passes them to the local relay.
- **Reading:** one local port per friend. The app points that friend's relay and Blossom URLs at
  `127.0.0.1:<port>`, so URLSession, AVFoundation, Coil and ExoPlayer need no changes.

## 4. Platforms

| Platform | Shares its vault? | Reads friends' vaults? | Notes |
|---|---|---|---|
| **Android** | Yes | Yes | Engine runs inside the relay's existing background service. Ships first. |
| **macOS** | Yes, 24/7 | Yes | Same core. Never suspended, so a good always-on home for your vault. |
| **iOS** | Only in opt-in "kiosk" mode | Yes | iOS suspends background apps. An old iPhone or iPad on a charger with the app open can host. |

iOS kiosk mode stays off by default: any app switch stops it, and it keeps the screen on.
Never use background audio, VoIP or location modes to keep it alive. That fails App Review.

## 5. Status and next steps

| Step | What | Who | Status |
|---|---|---|---|
| **1. Engine** | Upstream fips + app-owned TUN + smoltcp. Two networks, found through Nostr relays, direct link, no seed. | Tao | **Works.** Cut-off-file bug fixed (`8e2c598`). Branch `feat/fips-v2-upstream`. |
| 1b | Engine pieces for the app: sharing on/off, share and read at the same time, counters. | Tao | Open |
| 1c | Friends-only lock (§6). | Tao | Open. **Gates "Share my relay" on by default.** |
| **2. Android sharing** | Engine in the app; Settings → Mesh with "Who can reach you" and "Share my relay" (off by default). | Ted | **Built.** Phone → Mac on home Wi-Fi: 20 MB, 3 of 3 identical, ~17 MB/s. Branch `feat/android-fips-v2`. |
| **3. Android reading** | Vault adds its mesh address to its kind 10063 server list. The app reads a friend over FIPS, falls back to normal servers, shows a "via FIPS" badge. | Ted | Not started |
| **4. Real-world test** | Two phones, two networks, one on cellular. A full day of battery. Then an internal build. | Logen + Ted | Not started. Run the battery check early, as soon as sharing works. |
| **5. Mac, then iPhone** | Mac shares like Android. iPhone reads (plus kiosk). | Tao | After Android |

## 6. The friends-only lock

Today, a node that joins FIPS also joins the public mesh. In testing, strangers' nodes connected
to ours and one became our route parent. They can't read your vault (it's encrypted), but they
use your battery and data and can see your home address. Two fixes:

1. **Don't relay for strangers:** turn on `node.leaf_only` for phones. It's a setting, no code change.
2. **Only let friends connect:** FIPS has an allow list (`peers.allow`), but it only reads a fixed
   system file (`/etc/fips` or `/usr/local/etc/fips`) that an app can't write. We'll add a way to
   pass the list from the app, send that change upstream, and carry our own patch until it merges.

Note: `policy: configured_only` only limits whom *we* dial. It does not stop others connecting to us.

## 7. Risks

| Risk | What we'll do |
|---|---|
| Strangers connect to or route through your node | Friends-only lock (§6). Sharing off by default until it lands. |
| Battery drain from an always-open link | Measure a full day on the moto as soon as sharing works. If it drains badly, the Android design changes. |
| Slow, lossy links (a hotspot gave ~32 KB/s at 15% loss, 360 ms round trips) | Tune smoltcp buffers and retransmit. The ceiling is the link's own upload speed. |
| A missed connection offer stalls the connect | `signal_ttl_secs = 30` in the app (default 120, so 2 min). Real fix: re-send our offer when the peer's arrives unanswered. Patch to go upstream. |
| Same home network fails to punch (router doesn't hairpin) | Share LAN addresses, but only with friends on the allow list. |
| Upstream is git-only and changing (`fips` 0.6.0-dev on master) | Pin release tags, never master. Keep our patches small and send them upstream. |
| Upstream on Android was "compiles in CI" only | Now run on a real phone. The iOS build of upstream is still unverified. |
| App size | Android engine is 13.1 MB uncompressed for arm64, about 6 MB to download. Acceptable. |
| `MediaCacheService.isLocalURL` skips the disk cache for `127.0.0.1` | Only skip it for the vault's own relay port, or a friend's media re-downloads on every scroll. |
| A friend's cached media is lost when local ports change | Save the npub → port map to disk. Image and video caches key on the URL. |
| App Store review | No VPN entitlement and no system-wide routing. Describe it as in-app peer-to-peer, never "VPN". Check the export-compliance answer for the encryption used. |
| `.fips` addresses can't be reached by non-FIPS clients | Always list a normal (clearnet) Blossom server first in kind 10063. |

## 8. References

- Upstream FIPS: https://github.com/jmcorgan/fips (v0.5.2)
- smoltcp: https://docs.rs/smoltcp
- Blossom / BUD-03 (kind 10063): https://github.com/hzrd149/blossom
- Engine spike and notes: `fips-v2/README.md` on `feat/fips-v2-upstream`
