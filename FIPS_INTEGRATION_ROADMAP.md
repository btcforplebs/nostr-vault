# FIPS for Nostr Vault — Roadmap

**Goal: let friends reach your vault's relay and media directly, phone to phone or phone to Mac.
No public IP, no domain, no TLS certificate, no port forwarding, no VPN.**

*Rewritten 2026-10-07 for "v2", which is built on upstream `jmcorgan/fips` v0.5.2. The July
2026 version of this file planned everything around `fips-endpoint` (mmalmi's nvpn fork) and
said upstream FIPS could not be embedded in an app. Testing in September showed the opposite;
see "What changed" below.*

---

## 1. The short version

- Each vault runs a small FIPS mesh node inside the app. Each vault gets its own mesh key, and
  that key is its address. It is separate from your Nostr account key.
- Two vaults find each other by posting short signed messages on ordinary Nostr relays, then
  connect directly (UDP hole-punching with STUN). No middle server or "seed" node is needed.
- The vault's relay and Blossom media server already share one port, so one connection path
  carries both notes and media. The Go relay does not change.
- **Anyone can reach your vault, but your phone should never carry strangers' traffic.** That
  needs FIPS's leaf-only mode, which isn't working yet (§6), so "Share my relay" ships **off** by
  default until it is.

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
- **Reading (planned):** one local port per friend. The app points that friend's relay and Blossom URLs at
  `127.0.0.1:<port>`, so URLSession, AVFoundation, Coil and ExoPlayer need no changes.

## 4. Platforms

| Platform | Shares its vault? | Reads friends' vaults? | Notes |
|---|---|---|---|
| **Android** | Yes | Yes | Ships first. Today the engine starts with the app and stops when the app is killed. Planned: move it into the relay's background service. |
| **macOS** | Yes, 24/7 | Yes | Same core. Never suspended, so a good always-on home for your vault. |
| **iOS** | Only in opt-in "kiosk" mode | Yes | iOS suspends background apps. An old iPhone or iPad on a charger with the app open can host. |

iOS kiosk mode stays off by default: any app switch stops it, and it keeps the screen on.
Never use background audio, VoIP or location modes to keep it alive. That fails App Review.

## 5. Status and next steps

| Step | What | Who | Status |
|---|---|---|---|
| **1. Engine** | Upstream fips + app-owned TUN + smoltcp. Two networks, found through Nostr relays, direct link, no seed. | Tao | **Works.** Cut-off-file bug fixed (`8e2c598`). Branch `feat/fips-v2-upstream`. |
| 1b | Engine pieces for the app: sharing on/off, share and read at the same time, counters. | Tao | Open |
| 1c | Working leaf-only mode: no forwarding for strangers (§6). Built in our fork first. | Tao | Open. **Gates "Share my relay" on by default.** |
| 1d | Re-send a missed connect offer (the 2-min stall), as its own change in the same fork. | Tao | Open |
| **2. Android sharing** | Engine in the app; Settings → Mesh with "Who can reach you" and "Share my relay" (off by default). The list picks whom we connect to. It is not a block list. | Ted | **Built.** Phone → Mac on home Wi-Fi: 20 MB, 3 of 3 identical, ~17 MB/s. Branch `feat/android-fips-v2`. |
| **3. Android reading** | Vault adds its mesh address to its kind 10063 server list. The app reads a friend over FIPS, falls back to normal servers, shows a "via FIPS" badge. | Ted | Not started |
| **4. Real-world test** | Two phones, two networks, one on cellular. A full day of battery. Then an internal build. | Logen + Ted | Not started. Needs the engine in the background service first. Run the battery check early. |
| **5. Mac, then iPhone** | Mac shares like Android. iPhone reads (plus kiosk). | Tao | After Android |

## 6. Not carrying strangers' traffic

Anyone should be able to reach and read your vault. The real problem is different: today a phone
that joins FIPS also *forwards* other people's traffic. In testing, strangers' nodes connected to
ours and one picked our node as its route parent. They can't read your vault (it's encrypted), but
forwarding uses your battery and data.

The fix is FIPS's "leaf-only" mode: a node that can be reached by anyone, but never forwards
traffic and is never picked as a route parent. Upstream has designed it but not built it. In
v0.5.2 and on master, `node.leaf_only` only changes one internal setting, and the node still
forwards and can still become a route parent. So we build it ourselves (§6a).

Notes:
- `policy: configured_only` only limits whom *we* dial. It does not stop others connecting to us.
- A friends-only allow list is not the goal. It would also block people who should be able to read you.

### 6a. How we build and contribute it

Build first, then ask upstream:

1. Fork `jmcorgan/fips` to btcforplebs, with a branch off v0.5.2.
2. Build leaf-only there: reachable by anyone, never forwards other nodes' traffic, never picked
   as a route parent. The missed-offer re-send goes in as a separate change.
3. Test with unit tests, upstream's multi-node test harness, and a real phone ↔ Mac link.
4. Open the upstream issue and PR together, linked. Logen approves the exact text first.
5. The app uses our fork until upstream merges and tags a release, then switches back.

## 7. Risks

| Risk | What we'll do |
|---|---|
| Your node forwards strangers' traffic | Working leaf-only mode (§6). Sharing off by default until it lands. |
| Battery drain from an always-open link | Measure a full day on the moto as soon as sharing works. If it drains badly, the Android design changes. |
| Slow, lossy links (a hotspot gave ~32 KB/s at 15% loss, 360 ms round trips) | Tune smoltcp buffers and retransmit. The ceiling is the link's own upload speed. |
| A missed connection offer stalls the connect | `signal_ttl_secs = 30` in the app (default 120, so 2 min). Real fix: re-send our offer when the peer's arrives unanswered (step 1d). |
| Same home network fails to punch (router doesn't hairpin) | Share LAN addresses, but only with friends on your list. |
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
