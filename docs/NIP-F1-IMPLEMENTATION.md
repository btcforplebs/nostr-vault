NIP-F1 implementation note: Nostr Vault
=======================================

This note is not part of [NIP-F1](NIP-F1.md). It records how Nostr Vault implements the draft, and how features we know are coming fit the NIP without changing it. It changes as the app changes; the NIP should not.

## Status

Nostr Vault, checked against the code on 2026-10-22. Paths are in the `btcforplebs/nostr-vault` repository. "Merged" means merged into the 3.0 branch `integrate/v3.0.0` at `b59d9afc`, which is not released yet.

- **Media over the mesh: first tested on devices.** On 2026-10-09, an Android phone on a mobile hotspot read a photo from an iPhone's vault on home Wi-Fi over FIPS, unprompted in the app (`read 64629863 via mesh`, branch `feat/fips-open-reads` at `95b0845c`). The hardening in PR #465 then made the code match this text: `GET`/`HEAD /<sha256>` only, routing by the event's author, a full-body hash check, no `Range`, only `200`, and the exact address form.
- **Web page, live.** The public post page on nostrvault.app (`/thread/`, deployed from `master` at `0c973fa8`) reads a photo over FIPS in the visitor's plain browser when the photo's https server can't serve it. The visitor doesn't need to sign in or install anything.
  - The page server verifies the authors' `kind:10063` and writes each note's own author's mesh vaults on the image: `web-vault/thread-page/fetch.js` (`readMeshVaults`) and `page.js` (`MESH_SERVER`, `data-vaults`).
  - The browser runs a FIPS node with a throwaway key, reaches the mesh through public WebSocket seeds only (no WebRTC, no direct link), and asks only the vaults the page named: `web-relay/src/fips/photo-reader.js` (`startPhotoReader`).
  - It reads `GET /<sha256>` on port 80 and returns the body only if its hash matches: `web-relay/src/fips/blob-get.js`. Each photo is capped at 16 MiB, the page at 48 MiB, with 8 photos and 2 reads at a time: `web-relay/src/fips/share-photos.js`.
  - The bytes are shown through a `blob:` URL, the tab's local handle (`share-photos.js`, `toUrl`). The site keeps no copy of the photo: the server-side photo cache was removed in `0c973fa8`.
  - The page's CSP allows connections only to the two seeds (`website/nginx.conf`).
- **Mesh door, merged.** Mesh peers reach the vault's own HTTP handler, not the relay's full router: `haven-go/mesh_door.go` (`meshHandler`).
  - A stranger can only `GET`/`HEAD` a blob that a public note in the outbox names. Private kinds (4, 13, 14, 15, 1059) are skipped: `haven-go/mesh_safety.go` (`meshBlobIndex`) and `haven-go/init.go` (`meshBlobHandler`).
  - Uploads need an owner-signed `kind:24242`, checked before the body is read, at most 256 MiB, one at a time. The WebSocket on `/` accepts only events signed by the owner and answers no queries (`meshOwnerEventsOnly`).
  - Strangers come in on a separate network stack, capped at 1 MiB/s and 16 slots in total: `fips-v2-android/src/strangers.rs`. The owner's devices are kept apart by `own_devices.rs`. This is used by the iPhone kiosk, Android, and the Mac app (PR #987, merged at `20a0b575`).
- **Reader for follows only, merged.** Readers dial only the owner and authors the owner follows: `HavenApp/HavenApp/Services/MediaCache/MeshMediaRouter.swift` (`mayDial`), with the live check in `MeshMediaRouter+Live.swift`, and `NostrVault/app/src/main/java/com/nostrvault/fips/FipsMediaRouter.kt` (`mayDial`). The cap is 32 MB.
  - A follow's vault outside the owner's own devices is reached through the seeds without a direct dial (`read_anyone`), so it never learns the reader's address: `fips-v2-android/src/lib.rs` and `NostrVault/.../fips/MeshEnginePlan.kt`.
  - The Mac reads the same way since `0a810218` (`HavenApp/HavenApp/Services/MacFipsMeshService.swift`).
  - Device test of the follows path through the seeds: not yet.
- **Kept mesh key, merged.** The mesh key is its own key, made once, and stays on the device.
  - iPhone: Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`HavenApp/HavenApp/Services/FipsMeshService.swift`, `meshNsec`).
  - Mac: `MacFipsMeshService.swift` (`meshNsec`).
  - Android: one per install, apart from the account keys (`NostrVault/.../data/local/CredentialStore.kt`, `MESH_IDENTITY`; `fips/FipsMeshManager.kt`).
- **Publishing the media entry.** The app writes `fipsmesh://<npub>/` into `kind:10063` after the public servers: `HavenApp/HavenApp/Models/HomeVaultLogic.swift` and `NostrVault/.../service/nostr/NostrServiceListPublishing.kt`.
- **Relays: planned.** Nothing publishes a mesh relay entry in `kind:10002` yet, and no reader fetches notes over the mesh. The mesh door's WebSocket takes the owner's own events and serves no queries, so "Mesh relay policy" is not implemented yet.
  - The `kind:10002` form is settled in the NIP as a separate `fipsmesh` tag, not an `r` tag. Reason: nostr-tools 2.25.2 `normalizeURL` (`lib/esm/abstract-pool.js`) keeps unknown schemes, so a pool would try to open `fipsmesh://` as a relay; an unknown tag is ignored by every client.

## Changes in the 2026-10-22 future-proofing pass

All are loosenings or clarifications. The current code still conforms.

- The address may carry a query string; unknown parameters and fragments are ignored. Paths other than `/` are reserved and ignored.
- Several entries per list are allowed and stand alone. Readers may try more than one. (Code takes the first; still allowed.)
- `Range` is allowed (`206` for exactly the asked range). The hash check covers the whole blob before any byte is shown, played, stored or passed on. (Code sends no `Range`; still allowed.)
- Authentication may be by the peer's mesh npub when the owner has authorized it. This is what `own_devices.rs` does.
- The browser section names no seed and no app: any way of reaching the mesh, including #2469.
- The relay open question is closed: a separate `["fipsmesh", "<address>", "<marker>"]` tag, markers as in NIP-65. It may appear in any relay or server list (e.g. `kind:10050`).
- New "Extending this NIP" section: what may change without an edit, and what needs a new scheme.

## Coming features: does the NIP hold?

| Feature | NIP edit needed? | Why |
|---|---|---|
| Own seed (user runs their own FIPS entry node) | No | The NIP never names seeds. Routing and discovery belong to FIPS; "the same request, the same checks" whatever route is used. A seed hint, if ever wanted in the address, is an ignorable query parameter. |
| Warm routes / kept keys | No | Both are client or FIPS internals. The mesh npub is already SHOULD-kept; the reader's own key is not constrained. "Fail fast" sets no number. |
| Notes over the mesh (`kind:10002`) | No | Tag form decided now; read steps and relay policy already defined. Inbox-style entries later use a new marker, which old clients ignore. |
| Kiosk / own-devices door | No | Authentication by an owner-authorized mesh npub is allowed now. Strangers still get only what the public internet gets. |
| Uploads / writes to own devices | No | Other Blossom endpoints and owner-signed relay writes are allowed under "Mesh peers are strangers"; the auth-before-body rule covers uploads. |
| Several devices per user | No | Any number of entries, each standalone; readers may try several in order or at once. |
| Lost device / key rotation | No | Entries are hints; only the newest list counts. Owner-authorized mesh npubs MUST be revocable and are re-checked on every connection, so a stolen device's key stops working once revoked. |
| Video / large files | No | `Range` fetches allowed; caps follow what the client takes from public servers. Step 8 already allows early playback under a verification scheme bound to the same sha256 (e.g. a hash tree), so a later chunk-hash NIP plugs in without editing this one. |
| Own device as DM inbox (`kind:10050`) | No | A `fipsmesh` tag may sit in any relay or server list; its meaning follows the list's kind. |
| Several services on one node (kiosk door, separate relay/Blossom) | No | The address carries an optional port (default 80). |
| Browser capability #2469 | No | The browser section is written for any means of reaching the mesh. A client must not hand a `fipsmesh` address to a user agent or media element that skips the hash check. |

## Tron adversarial pass (2026-10-22) and code to check

Reviewer: Tron. All 7 must-fixes and 7 optionals applied in the NIP. These rules are new, and nobody has yet checked the code against them:

- Lowercase-only npub and decoded-key comparison in the address parsers (iOS, Android, Mac, web).
- Addresses with a port: readers must ignore them (not dial 80) until ports are supported.
- Mesh upload authorization: `kind:24242` must carry a `server` tag naming this vault's mesh address or npub, and be unexpired.
- Revoking an own-device mesh npub (`own_devices.rs`), re-checked per connection.
- Stranger blob index drops blobs whose events were deleted (NIP-09) or replaced.
