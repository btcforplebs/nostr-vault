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
  needs a "leaf" mode that never forwards for others. We've built it in our copy of FIPS (§6);
  "Share my relay" stays **off** by default until it's in a release build of the app.

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
| 1c | Leaf mode on today's FIPS: many links, no forwarding for strangers (§6). | Tao | **Built** in our fork, branch `leaf-only`. Reviewed by Tim and Tron. Phone ↔ Mac: 20 MB, 3 of 3 identical. **Gates "Share my relay" on by default.** |
| 1d | Re-send a missed connect offer (the 2-min stall). | Tao | **Built** in our fork, branch `offer-resend`. Reviewed. |
| 1e | Help build upstream's v1.0 (§6b). | Tao | In progress. Reviews: Tim, Tron. |
| **2. Android sharing** | Engine in the app; Settings → Mesh with a friends list and "Share my relay" (off by default). The list picks whom we connect to. It is not a block list. The screen still labels it "Who can reach you"; rename to "Friends I connect to" in the app. | Ted | **Built.** Phone → Mac on home Wi-Fi: 20 MB, 3 of 3 identical, ~17 MB/s. Branch `feat/android-fips-v2`. |
| **3. Android reading** | Vault adds its mesh address to its kind 10063 server list. The app reads a friend over FIPS, falls back to normal servers, shows a "via FIPS" badge. | Ted | Not started |
| **4. Real-world test** | Two phones, two networks, one on cellular. A full day of battery. Then an internal build. | Logen + Ted | Not started. Needs the engine in the background service first. Run the battery check early. |
| **5. Mac, then iPhone** | Mac shares like Android. iPhone reads (plus kiosk). | Tao | After Android |

## 6. Not carrying strangers' traffic

Anyone should be able to reach and read your vault. The problem was that a phone joining FIPS
also *forwarded* other people's traffic: in testing, strangers' nodes connected to ours and one
picked our node as its route parent. They can't read your vault (it's encrypted), but forwarding
uses your battery and data. A friends-only allow list is not the goal, because it would also
block people who should be able to read you.

What we need is a "leaf": a node anyone can reach, with links to many friends at once, that never
forwards traffic for others and is never picked as a route parent.

Where upstream FIPS stands:
- **v0.5.2 (today's release, and master):** the `node.leaf_only` setting does nothing to forwarding.
- **`next` (v1.0, not released):** has two modes. "Leaf" allows only **one** link, which doesn't fit
  us, because every friend gets their own direct link. "Non-routing" (`disable_routing`) allows many
  links and is the right shape. v1.0 can't talk to any v0.5.x node, which is every node on the mesh today.

## 6a. Ship track: our copy of today's FIPS

The app runs our fork, `btcforplebs/fips`, on v0.5.2, with two changes:

- **Leaf mode** (`leaf-only`): many links, never forwards for others, never a route parent.
  Tested with 7 unit tests, upstream's multi-node harness (5-node ring, the leaf forwarded 0
  packets and no node routed through it), and a phone ↔ Mac link.
- **Offer re-send** (`offer-resend`): fixes the 2-min connect stall.

**Known gap:** if the phone's mesh address is the smallest of every node it can see, it ends up cut
off and only direct links reach it. Logen's phone is fine against the Mac. The proper fix is coming
on the upstream track.

This copy gets fixes only, no new features. When v1.0 ships, the app moves to it and the fork goes away.

## 6b. Upstream track: help build v1.0

Nostr Vault is the first app to run FIPS over Nostr relays, so we hit gaps upstream hasn't yet.
We build fixes on `next` in our fork, test them, and offer them to jmcorgan, one change per PR:

| # | Gap on `next` | Status |
|---|---|---|
| 1 | The 2-min connect stall (same code as v0.5.2). | Ready, branch `next-offer-resend`. **Waiting on Logen's OK on the PR text.** |
| 2 | A non-routing node with the smallest address gets cut off (upstream lists it as open). | Split in two: 2a built (`next-recover-skip`), 2b in progress. |
| 3 | Two phones can't link: `next` needs a "full" node on every link, and friend ↔ friend is usually phone ↔ phone. | Not started. Changes a protocol rule, so needs jmcorgan's agreement most. |

Each change gets unit tests, a run in upstream's multi-node harness, a phone ↔ Mac test, and a
review by Tim and Tron. **Nothing goes upstream (issue, PR or comment) until Logen approves the
exact text in #FIPS.**

## 7. Risks

| Risk | What we'll do |
|---|---|
| Your node forwards strangers' traffic | Leaf mode in our fork (§6a). Sharing off by default until it's in a release build. |
| A leaf phone with the smallest address gets cut off | About a 1-in-N chance per key (N = nodes it sees), and fixed for that key. Proper fix on the upstream track (§6b, gap 2). |
| Battery drain from an always-open link | Measure a full day on the moto as soon as sharing works. If it drains badly, the Android design changes. |
| Slow, lossy links (a hotspot gave ~32 KB/s at 15% loss, 360 ms round trips) | Tune smoltcp buffers and retransmit. The ceiling is the link's own upload speed. |
| A missed connection offer stalls the connect | `signal_ttl_secs = 30` in the app (default 120, so 2 min). Real fix: re-send our offer when the peer's arrives unanswered (built, §6a). |
| Same home network fails to punch (router doesn't hairpin) | Share LAN addresses, but only with friends on your list. |
| Upstream v1.0 breaks compatibility with v0.5.x | Stay on our v0.5.2 fork until v1.0 ships, then move everything at once. Help shape v1.0 now (§6b). |
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
