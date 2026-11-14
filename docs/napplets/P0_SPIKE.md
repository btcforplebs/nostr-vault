# Napplets P0 spike: findings

**Date:** 2026-11-14. **Branch:** `tal/web-napplet`. **Plan:** P0 of the napplet direction (shell first, then
first-party napplets one screen at a time). Nothing here is deployed; nostrvault.app is unchanged.

## What was built

| File | What it is |
|---|---|
| `web-vault/src/napplet/host.js` | `mountNapplet()`: sandboxed frame (`allow-scripts` only), artifact hash, one `napplet.hello` port, per-domain dispatch with an allowlist, revoke on any other window message or a second load |
| `web-vault/src/napplet/srcdoc.js` | Pure: SHA-256 artifact hash, bootstrap injection first in `<head>` |
| `web-vault/src/napplet/csp.js` | The frame's own CSP: default deny, no network, images/media from `blob:`/`data:` only |
| `web-vault/src/napplet/prelude.js` | Inlines `@napplet/shim` 0.38.1 `prelude.global` (pinned exact) and installs only the granted domains |
| `web-vault/napplets/note-drafts/index.html` | Sample napplet, plain JS: identity, storage autosave, outbox publish, outbox query |
| `web-vault/napplets/bench/index.html` | Bench napplet: hop cost, thumbnails, big blobs, video, sandbox probes |
| `web-vault/napplet-spike.html` + `src/napplet/spike/spike-shell.js` | Dev-only shell page. Not a build input (vite builds `index.html` only). Throwaway key made per load, never stored |
| `web-vault/test/napplet-host.test.mjs` | Hash and bootstrap-order tests (mutation-checked: moving the bootstrap to the end of `<head>` fails) |

**Run it:** `cd web-vault && npm ci && npx vite --port 5231`, then open
`http://localhost:5231/vault/napplet-spike.html`. Left: Note Drafts. Right: the bench; its results land in the page
title as JSON.

## Results (headless Chrome, this Mac, 2026-11-14)

**Note Drafts works end to end.** It read the shell's pubkey, autosaved through `storage.set`, published through
`outbox.publish` (the shell signed a kind 1 with its key; the napplet never saw one), and the new note came back on
its next `outbox.query`.

**The sandbox holds.** Inside the frame: `origin` is `null`; `fetch`, `WebSocket` and a remote `<img>` are all
refused; `localStorage` and `indexedDB` throw; `window.nostr` is absent.

**Revocation works.** A second window message, a second hello and a `location.reload()` each removed the frame. A
quiet napplet stayed mounted.

**The port hop is cheap.** Round trips measured from inside the napplet, 25 runs each:

| Request | Median | First run |
|---|---|---|
| `identity.getPublicKey` (empty hop) | under 0.1 ms | |
| `outbox.query`, 20 notes | 0.1 ms | 0.4 ms |
| `outbox.query`, 200 notes (40-900 chars, 2-7 tags) | 0.4 ms | 2.8 ms |
| `resource.bytesMany`, 30 JPEG thumbnails (1.3 MB) | 0.7 ms | |
| 30 thumbnails, bytes to all decoded | 16.8 ms | |
| `resource.bytes`, 5 / 25 / 50 MB blob | 0.5 / 0.1 / 0.1 ms | |

Blobs cross the port by reference, not by copy, so size barely matters. The structured clone of 200 notes costs well
under a frame. The napplet split adds nothing a user can feel on top of today's Haven read (see NV_WEB_SPEED for that).
The timer inside the sandbox is coarsened to 0.1 ms, so the small numbers are upper bounds.

**Video works inside the napplet; the shell only fetches bytes.**
- A 2 s VP8 clip fetched with `resource.bytes`, turned into a `blob:` URL and played in a `<video>`: playing after
  21.5 ms.
- `MediaSource` exists in the opaque-origin sandbox and a `SourceBuffer` took the clip (1.98 s buffered). That is
  what hls.js needs, so HLS can run inside a napplet with a loader whose segment fetch is `resource.bytes`.
- NAP-MEDIA is not playback: it is now-playing metadata and play/pause commands
  (`media.session.create`, `media.command`). Nothing in the NAPs plays video for a napplet.
- `resource.bytes` has no byte range. A long progressive MP4 has to arrive whole before it plays. That is the one
  video gap; see decision 4.

**Single-file size.** Today's Feed + Thread + Person screens bundled as one IIFE (vault engine stubbed out, since the
shell keeps it):

| Bundle | Raw | gzip | brotli |
|---|---|---|---|
| As they are today, with hls.js | 1,066 KB | 344 KB | |
| Without hls.js | 502 KB | 170 KB | 137 KB |
| CSS (whole app today) | 75 KB | 14 KB | |
| Prelude added to every frame | 204 KB | 37 KB | |

`src/net` is 44% of the unminified feed code. Most of it (pool, relays, sync) moves to the shell, so the real feed
napplet should land well under 137 KB brotli. hls.js should not ride in the feed napplet: either a separate video
napplet reached by intent, or `hls.js/light` loaded only when a stream is opened. Size is not a blocker.

## The CSP blocker, and the fix for P1

A `srcdoc` frame (and a `blob:` frame) **inherits the parent page's CSP**. Under the live vault CSP from
`website/nginx.conf` (`script-src 'self' 'wasm-unsafe-eval'`), a napplet's inline scripts, including the prelude,
do not run. Checked with a local server sending that exact header: the srcdoc and blob frames stayed silent.

Loosening the shell's own `script-src` to `'unsafe-inline'` would undo the shell's XSS protection, so not that.

**Fix (tested):** a served loader page, `/vault/napplet-frame.html`, sent with its own CSP header (default deny, inline
script allowed, no network). The shell frames it with `sandbox="allow-scripts"`. When it says it is ready, the shell
posts it the verified srcdoc (bootstrap + napplet bytes), and it replaces itself with `document.open/write/close`.
Checked under the vault header: the written napplet's inline script ran, `origin` stayed `null`, `fetch` and
`localStorage` stayed blocked. One difference: the write fires a second `load`. The host has to expect exactly two
loads (loader, then napplet) and revoke on the third.

P1 ships that loader, its nginx `location` with its own CSP, the same header in vite dev, and the host change. The
spike page still uses plain `srcdoc` because vite dev sends no CSP.

## Decisions

1. **Own runtime, not @kehto/shell.** Kehto 0.34 is a full runtime (about 1.2 MB of dist across shell and runtime). It
   keeps grants in `localStorage` (`napplet:acl`), brings its own relay and auth hooks, and its own fixture napplets
   still sit on an older core line (0.32). We need haven.wasm first, NIP-42 AUTH and the .fips rules in the dispatch,
   and now the loader for our CSP. The spike's host is about 80 lines on the maintained prelude. Keep it ours; read
   Kehto's code for the consent UI wording.
2. **Vault-private data to third-party napplets:** off by default (Logen's lean, kept). Enforced by the dispatch
   allowlist and per-napplet grants in the shell, never by the shim.
3. **Catalog publishing:** none until Logen says (Tod's brief). First-party napplets are built and tested locally
   only.
4. **Video: settled.** Playback lives in the napplet; the shell fetches bytes (`resource.bytes`, the shell's IP and
   .fips rules apply). Short clips go whole as a `blob:`; HLS runs on MediaSource with a `resource.bytes` loader.
   Long progressive MP4s need byte ranges: P1 adds `range` to our shell's `resource.bytes` as an optional extension,
   and the napplet falls back to whole-file where a shell lacks it.

## Next: P1 shell runtime

The loader page and CSP above; manifest checks; consent UI; dispatch for identity, shell, theme, storage (shell
IndexedDB, per dTag + hash), outbox (Haven first, then the pool, AUTH inside), relay, resource (vault, .fips, the
user's servers, https under the IP rules), upload, intent, inc and notify. Hidden behind `?shell=1`.
