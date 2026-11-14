# Napplets P6: the WoT globe as a napplet (the shell computes, the napplet draws)

Plan: RESEARCH/NV_WEB_NAPPLET_PLAN.md §6 (P6). Local only: nothing published or deployed.

## What changes for the user

With the napplet switch on, the **WoT tab** (`#/wot`, and `#/wot/<hex>` with that person's card open) is the WoT
napplet (`napplets/wot/index.html`, `src/napplet/WotPane.jsx`). It has:

- the globe: drag, flick, pinch, wheel, double-click to go home, and arrow keys
- the layer picker with counts
- Follow you back
- Find, which matches a name, a word of it, a phrase in it, or a key
- trust cards with the path traced, and Open profile
- ↻, which reads the follow lists again

"See their web" (`#/wot/<hex>/web`) is still the classic screen, and so are follow and unfollow on a card: kind 3
is an account list, never signed for a napplet.

Switch off: the classic WoT tab.

## How it splits (Logen's decision 6)

- **Shell** (`WotPane.jsx`) builds the web exactly as the classic tab does:
  - `followLists`, `buildWeb`, `filterWeb` with the block list
  - the drawn caps (`shownByKey`)
  - the face candidates' profiles (strangers' kept in memory only)

  It then sends a scene (`wot-scene.js sceneOf`) by intent (`napplet:wot/show`): drawn people, links as indices
  into your follows, who follows you back, names and https pictures, and full counts. Before the lists arrive it
  sends a waiting scene with the status line.
- **Napplet** only draws. It has `resource`, `intent` and `theme`, with no relay or outbox domain, so it can't
  read the network at all. Pictures are bytes from the shell. It asks back for `napplet:profile/open` and
  `napplet:wot/refresh`, which the shell answers itself.
- **One copy of the maths.** The pure WoT pieces moved into `net/wot-pure.js` (no imports; `net/wot.js`
  re-exports them). `wot-inject.js` puts it and `net/wot-globe.js` into the napplet at build, in place of
  `/*@wot-maths*/`. The draw loop is WotGlobe.jsx's, ported line for line.

## Fixed in passing: shell-started intents were never delivered

The shim drops any `intent.deliver` whose `convention` isn't `napplet:<archetype>/<action>`. Every intent the shell
started itself carried `convention: ""`, so none arrived:

- P4's `#/thread/<id>` and `#/profile/<pk>` opening in the Reader. P4's check passed by mistake: the text it waited
  for was also in the feed.
- P5's Media pill choosing the napplet's filter.

`bus.js` now fills `napplet:<archetype>/<action>` when none is given. A test runs the shim's own `isIntentDelivery`
on what the bus sends. The P4 deep link is now checked properly in Chrome: Reader title "Thread", the linked note in
focus.

## Checked

- `npm test`: 2363 pass, 7 new (`napplet-wot.test.mjs`). Highlights:
  - **Parity:** runs the napplet's script as shipped (injected maths + pure block) and gets exactly the classic tab's
    globe layout (nodes, faces, ring faces) for all 4 layers with Follow you back on and off, plus identical
    trust-path lines.
  - The test asserts its web isn't empty: vouched, further out, follow-backs and outer faces are all there. A first
    version of the fixture was silently empty.
  - **Mutation:** dropping the lit filter on ring faces fails the parity test; the old bus fails the delivery test.
- **Real app** (headless Chrome, vite dev, throwaway keys, fake relay with 14 follows and 80 others):
  - The globe draws with counts Everyone 72 / Following 14 / Vouched 8 / Further out 50.
  - Find "cleo" → card "You follow them · also followed by Bob". Find "outer 30" → card "Followed by Finn, Jo + more
    you follow · 2 hops", with the trace lines.
  - Vouched layer works; Follow you back says "5 follow you back".
  - Open profile → `#/profile/<pk>`. `#/wot/<hex>` opens that card.
  - Switch off → the classic globe.
  - All 34 picture fetches came from the vault page, none from the napplet.
- **Caught before merge:**
  - the delivery bug above
  - Find failed on a full name with a space
  - ↻ wrapped to a second row on a phone
  - the pane sent nothing while the lists loaded (now a waiting scene)
