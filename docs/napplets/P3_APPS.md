# Napplets P3: the Apps pane

Plan: RESEARCH/NV_WEB_NAPPLET_PLAN.md §6 (P3). Local only: nothing is published to a catalog, nothing is deployed.

## What it is

`#/apps` (Vault menu → Apps, listed only while the napplet preview switch is on) and `/vault/?shell=1` (where the
switch is) show one pane, `src/napplet/NappletShell.jsx`:

- **Installed:** this account's apps. Open, Access, Update (when the catalog has a newer manifest), Remove.
- **Nostr Vault's own:** Emoji, Note Drafts, and Open a file….
- **Catalog:** kind 35129 manifests from the user's read relays (`shell-deps.js readCatalog`), newest per
  (publisher, d tag), signatures checked, publishers on the block list left out. One that needs a domain this shell
  doesn't answer (e.g. `dm`) is listed with the reason and can't be installed.

Rules are in `src/napplet/catalog.js` (pure, tested in `test/napplet-apps.test.mjs`).

## Install, open, update, remove

- **Install:** the artifact is fetched from Blossom: the manifest's `server` tags, then the publisher's kind 10063,
  then the usual servers. Its bytes must hash to the manifest's `x` (`fetchVerified`), 5 MB at most. Then it opens,
  which shows the consent sheet; the app is kept (manifest event in localStorage `nv-napplet-apps:<pubkey>`, bytes in
  IndexedDB `nv-napplet-apps:<pubkey>`) only if the user said yes.
- **Open:** the kept bytes; the runtime checks the hash again on every mount. Fetched again only if the bytes are gone.
- **Access:** the consent sheet again, with what the user said before. Saving closes the app if it is open, so the
  new access applies on the next open. Same grant shape and the same choices as the first time: the rules in
  `policy.js` are unchanged (decision 2 stays as it is while Logen answers the WebRTC question).
- **Update:** a newer manifest with another hash is another napplet (NIP-5D identity is d tag + hash), so it is asked
  again. After the user says yes, the old version's grant, its own storage and its bytes go (`retireVersion`); the
  app's shared storage carries over.
- **Remove:** the app, every version's grant and storage, the shared storage and the kept bytes (`removeApp`). Only
  `<publisher>:<d>:<64 hex>` keys count as versions, and storage is cleared one exact scope at a time
  (`storage-idb.js clear` used a prefix range before: removing `pub:foo` would have wiped `pub:foobar`).

Outside napplets still open only where there is a napplet host (P2): on the live site Install says why it can't.

## Checked

- `npm test`: all green, 11 new. Mutation: dropping the 64-hex check in `removeApp` turns its test red.
- Real app, headless Chrome, vite dev, throwaway keys, fake relays and fake Blossom (nothing left the machine):
  catalog shows Tally (installable) and DM Reader (disabled: "no dm"); Install fetched once from Blossom, consent,
  Tally ran on `n-7759….localhost` and read the right pubkey; Access with identity off closed it and the reopen had no
  identity (no second fetch: kept bytes); Look again found v2, Update asked again, v1's grant gone; Remove left no app,
  no grant, no bytes, no storage rows and no frame. 0 events published.
- The run caught a bug before merge: Update left v1's own storage behind, where Remove could no longer find it.
  Fixed with `retireVersion`, tested.
- Tron review (PASS): S1 fixed. Catalog rows show the letter icon only; loading the publisher-named `icon` URL would show that host the IP of everyone who opens the catalog. `entry.picture` stays parsed for a later fetchVerified/blob path. S2 (bytes keyed by hash only, Remove can drop another app's identical artifact) is harmless: it refetches on next open.
