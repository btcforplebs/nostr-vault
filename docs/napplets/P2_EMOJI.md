# Napplets P2: the Emoji napplet, and each napplet on its own origin

**Date:** 2026-11-14. **Plan:** P2 of RESEARCH/NV_WEB_NAPPLET_PLAN.md, plus closing the leak gap P1 left open
(P1_RUNTIME.md, "What 'no network' does not cover"). Nothing deployed; nostrvault.app unchanged. Not published as a
35129 manifest: Logen's decision 3 publishes our napplets only after P8.

## What ships

| File | What it is |
|---|---|
| `web-vault/napplets/emoji/index.html` | The Emoji napplet: Unicode emoji by category with search, your recent picks (NAP-STORAGE), and your own custom emoji (your kind 10030 and the 30030 sets it names, NIP-30). Pictures come as bytes from the shell (`resource.bytes`); the frame has no network. A pick goes out on the INC topic `nv.emoji.picked` as `{ emoji }` or `{ shortcode, url }` |
| `src/components/emoji-data.js` | The emoji and search words, shared by the reaction picker and (as a test-checked copy) the napplet |
| `src/napplet/emoji-intent.js` | Compose joins the shell's bus as a participant, asks for archetype `emoji`, action `pick`; the bus opens the handler and delivers; picks come back on the topic. A pick is checked again here: a plain emoji, or a shortcode with an https picture |
| `src/napplet/ComposeEmoji.jsx` | Compose's emoji sheet when napplets are on: the Emoji napplet in a Dialog, own lazy chunk |
| `src/screens/ComposeScreen.jsx` | New Emoji button. Napplets on: the napplet; off: the reaction picker's sheet ("Add Emoji"). A custom emoji puts `:shortcode:` in the text and an `emoji` tag on the note for each one still in it; the draft keeps them |
| `src/napplet/flag.js` | "Use napplets in the app (preview)", switched on the `?shell=1` page. Off by default |
| `src/napplet/origin.js` | Each napplet's own origin: `n-<first 32 hex of its artifact hash>.<napplet host>` |
| `src/napplet/csp.js` | The napplet-origin loader's headers, and `nappletOriginFile`: a napplet origin serves its loader and its service worker, nothing else (vite dev and `server.mjs` both use it) |
| `web-vault/public/napplet-frame.html` | The loader, now with guards when it has a real origin (below) |
| `web-vault/public/napplet-sw.js` | The napplet origin's service worker: every request but the loader and itself gets a network error |
| `web-vault/tools/napplet-leak-check.mjs` | Real-Chrome leak check (below). Not in `npm test`: it needs a browser |

## Own origin: why, and what it buys

P1 framed napplets `sandbox="allow-scripts"` on the vault's origin, so their documents had an opaque origin. That kept
them away from the vault, but an opaque document gets no Navigation API and no service worker, so nothing could stop
a napplet navigating its own frame to `https://author.example/?data=…`.

P2 gives each napplet a real origin that is its own, never the vault's: `allow-scripts allow-same-origin` is safe
there because the origin it grants is the napplet's. The shell refuses to mount a napplet on the vault's own origin.
On that origin the loader, before it writes the napplet over itself:

1. registers `napplet-sw.js` and waits until it controls the page;
2. adds a Navigation API `navigate` listener that cancels every navigation of the frame and tells the shell, which
   closes the napplet ("it tried to leave its frame"). `document.open` keeps the listener (checked);
3. removes `RTCPeerConnection` and the other `RTC*` constructors from the window (a speed bump only, see the gap);
4. reports `{ nav, sw }` in its ready message. Outside napplets mount only with both up; else the frame is removed
   with the reason.

The CSP stays default-deny (no fetch, frames, forms, workers but `blob:` and the one service worker), `frame-ancestors`
names the vault's origin only, and `X-DNS-Prefetch-Control: off`. A separate origin per napplet also keeps napplets'
own storage and workers apart from each other.

**Where napplets run:**
- A build with `NV_NAPPLET_HOST=nvapps.example`: `https://n-<id>.nvapps.example`. Needs wildcard DNS and a wildcard
  certificate; that host should be its own registrable domain on the Public Suffix List, so each napplet is its own
  site and can't set cookies for its neighbours or the vault. Not set up (local only).
- On this machine: `http://n-<id>.localhost:<port>` (Chrome and Firefox resolve `*.localhost` to loopback).
- Anywhere else (nostrvault.app today): no napplet host, so **outside napplets won't open** ("This site can't wall off
  an outside napplet yet"), before any consent sheet. Our own napplets still run, on the P1 loader.

## Checked

- **Leak check, real Chrome** (`node tools/napplet-leak-check.mjs`): a hostile napplet tries fetch, image, beacon,
  blob worker, child frame, popup, form, link click, meta refresh, `navigation.navigate`, `location =` and WebRTC.
  Control (P1 loader): the link click leaks. P2 loader: guards `{nav: true, sw: true}`, **nothing arrives** at the
  author server, every navigation is cancelled and reported, no `RTCPeerConnection` on the napplet's window.
  The check fails if the control stops leaking, so it can't pass by seeing nothing.
- The check also caught a bug before it shipped: the loader first read `location.origin` (the URL's, never "null"),
  so on the P1 loader it touched `navigator.serviceWorker` and threw. It reads `self.origin` now.
- **The app, headless Chrome, throwaway key, vite dev:** shell page and compose both mount the Emoji napplet on
  `n-e58c….localhost` (an out-of-process frame, service worker in control, `fetch` blocked, no `RTCPeerConnection`).
  In compose a 🔥 and a custom `:soapbox:` land at the caret; a pick with an `http:` picture is dropped; the napplet
  doing `location.href = …` is closed. Switch off: the old sheet, and its pick lands too.
- `npm test`: 2323/2323, 10 new (test/napplet-emoji.test.mjs, test/compose.test.mjs). Mutation-checked: emoji tags
  not tied to the text, `http:` pictures allowed, the no-origin refusal, the loader's sandbox header, the napplet host
  each fail a test.

## The gap that is left: WebRTC through a child frame

A napplet on a real origin can make an `about:blank` child frame, which is same-origin with it and has its own,
untouched `RTCPeerConnection`. The leak check measures it: 5 STUN packets reach a STUN server the napplet names.
That gives the author the user's IP, and data can be carried in what the napplet controls of the ICE exchange.
What was tried, in Chrome:

- CSP `webrtc 'block'`: not enforced (STUN still sent).
- Stripping the child's `RTC*` on its `load`: the load event comes too late; `window[0]` is in hand at once.
- Snow-style hooks on every way to make a frame: Snow itself says it can't hold where inline script is allowed, and a
  napplet is inline script.

There is no browser switch for WebRTC today. On the P1 loader (opaque origin) the child frame is out of reach and
WebRTC is closed, but navigation is open, which is the easier and bigger leak; P2 trades that for this one. So an outside
napplet can still tell its author the user's IP, and one with the private-data grant could send what it read. The
private-data words already say so (P1). Whether outside napplets should get that grant at all until browsers can block
WebRTC is Logen's call (his decision 2).

## Not in P2

- Publishing the Emoji napplet's 35129 manifest and checking it in Kehto/Paja and Myco: after P8 (decision 3).
- The napplet host on the live site (DNS, certificate, nginx server block).
- Reactions still use the app's own sheet; the napplet is compose's.
