> **Draft, not yet submitted.** This NIP has not been proposed to the [nostr-protocol/nips](https://github.com/nostr-protocol/nips) repository. It lives here while Nostr Vault builds against it, and it may change.

NIP-F1
======

Nostr over the FIPS Mesh
------------------------

`draft` `optional`

This NIP lets a user's own device act as one of their relays and one of their Blossom servers, even though it can only be reached over the [FIPS](https://github.com/jmcorgan/fips) mesh. It defines one address form, `fipsmesh://<npub>/`, and how clients use it to:

- read the user's notes from that device (the outbox model, [NIP-65](https://github.com/nostr-protocol/nips/blob/master/65.md)), and
- read the user's media from that device ([NIP-B7](https://github.com/nostr-protocol/nips/blob/master/B7.md) `kind:10063`, detailed in [BUD-03](https://github.com/hzrd149/blossom/blob/master/buds/03.md)).

With this, a phone or home computer can serve its owner's notes and media directly to other users. It doesn't need a public address, a domain name, or a third-party server. The NIP defines no new event kinds.

**Scope.** This NIP covers only Nostr data: one entry in a user's existing lists (`kind:10002`, `kind:10063`), and how Nostr clients read notes and blobs from it. It does not specify FIPS. How a FIPS node is found, connected to and addressed is defined by the [FIPS specification](https://github.com/jmcorgan/fips), and this NIP only refers to it.

A browser capability for reaching FIPS addresses is proposed separately ([#2469](https://github.com/nostr-protocol/nips/pull/2469)). Web clients could use it to carry out these reads, but this NIP doesn't depend on it.

## Motivation

On Nostr, notes are trusted because they are signed, and media is trusted because it is addressed by hash. Neither depends on which server delivered it. But every relay in a `kind:10002` and every server in a `kind:10063` must be reachable over the public internet. Most personal devices aren't: they sit behind NAT, change networks, and have no stable address.

FIPS is a mesh network where every node is identified by a Nostr key pair, and nodes find each other through Nostr relays. Any FIPS node can reach a device by its npub, from any network. This NIP lets such a device take part in the outbox model and in Blossom as an ordinary relay and server.

## Terms

- **Mesh node:** a FIPS node. Its identity is a secp256k1 key pair, written as an npub.
- **Mesh npub:** the npub of the mesh node that hosts the service. This SHOULD be a separate key from the user's Nostr identity key, so the user's main key never sits in a network daemon. The device SHOULD keep this key across restarts and only replace it when the user asks. A listed entry names the key, so a new key on every start would make every published list point at a node that no longer exists.
- **Mesh address:** the IPv6 address FIPS derives from a mesh npub (`fd00::/8`).
- **Mesh service:** a relay and/or Blossom server listening on its node's mesh address.

## The `fipsmesh` address

```
fipsmesh://<mesh-npub>/
```

It means "connect to this npub over FIPS, on TCP port 80."

- The authority is the bech32 `npub` of the mesh node. It has no port and no user info.
- The path MUST be exactly `/`. The trailing slash is required: `fipsmesh://<npub>` without it is not well formed, and clients will ignore it. There is no query or fragment.

A client MUST check that the whole address is well formed before using it, and MUST ignore any address that isn't. A client MUST NOT treat the npub as a DNS name, and MUST NOT turn the address into an `http(s)` or `ws(s)` URL on the public internet.

## Transport

The mesh service listens on **TCP port 80** at its mesh address. The port is fixed by this NIP. A different port would need a new scheme. On that port it serves:

- plain HTTP/1.1 for Blossom, and
- a NIP-01 relay, reached by a WebSocket upgrade on `/`.

A service MAY offer only one of these. Requests are sorted by header, not by path:

- A request with `Upgrade: websocket` goes to the relay.
- A request with `Accept: application/nostr+json` is a [NIP-11](https://github.com/nostr-protocol/nips/blob/master/11.md) request for the relay's information document.
- Any other request goes to Blossom.

A service that offers only Blossom MUST refuse WebSocket upgrades and NIP-11 requests. It MUST NOT hand them to a relay that shares its HTTP server. Many relay frameworks pick the relay by these headers on any path, so mounting Blossom next to a relay can serve the relay by accident.

Plain HTTP and WebSocket are used on purpose. FIPS authenticates both ends by their keys and encrypts the session end to end, so TLS would add nothing. The service MUST NOT expose its mesh endpoint as unauthenticated plain HTTP on any non-mesh network interface.

If the mesh endpoint is also reachable on loopback, for example because the mesh engine forwards to it there, it MUST offer nothing more on loopback than it offers mesh peers. It SHOULD exist only while the device is serving on the mesh. Loopback ports are reachable by every app on the same device. This rule covers only the endpoint that serves the mesh, not other services the device runs.

### Mesh peers are strangers

Being on the mesh grants no extra rights. A mesh peer MUST be treated as an unknown remote client, never as a local one. It MUST NOT inherit any trust, authorization exemption, or rate-limit allowance that the service gives to connections from its own device.

Anything the service would not give to an anonymous client on the public internet MUST NOT be given over the mesh without authentication. That means NIP-42 for the relay, and BUD-02 `kind:24242` for Blossom.

A service SHOULD limit how much one mesh peer can take, in requests and in bytes. It SHOULD stop serving, or ask its owner, once its total upload passes a limit the owner sets.

## Relays

### Listing a mesh relay

> **Open question, being settled before submission:** whether the entry is an `r` tag in `kind:10002` (`["r", "fipsmesh://<npub>/", "write"]`) or a separate tag in the same event (`["fips", "<npub>"]`). This depends on how existing clients handle `r` tags with an unknown scheme. The worst case is a client that rejects the whole `kind:10002` because of one entry it can't parse, which would break the user's whole outbox. A separate tag can't cause that, so it is the default unless every major client is shown to skip such entries cleanly. The rules below hold either way.

1. The entry describes where the user's notes can be **read**. In NIP-65 terms it is a write (outbox) relay.
2. A user MUST NOT list a mesh relay as their only write relay. Notes have to stay reachable for clients without FIPS.
3. A mesh relay entry SHOULD come after the user's public relays. Clients that pick a few relays from the list SHOULD NOT count the mesh relay as one of them, and SHOULD use public relays first.
4. The user's client SHOULD publish each event to the mesh relay as well as to the user's public relays. It SHOULD list the mesh relay only while the device is actually serving.

### Reading notes over the mesh

1. Get the author's `kind:10002` and verify it (see "Client behaviour").
2. If it lists a mesh relay, the client supports FIPS, and the author passes the dialing rule in "Client behaviour", connect to the mesh npub through FIPS, as the FIPS specification describes.
3. Open a WebSocket to `/` on the node's mesh address, port 80, and send `REQ` as with any relay.
4. Verify every event's signature as usual. A mesh relay is trusted no more than any other relay. Drop any event not signed by the author, and apply the stream limits in "Client behaviour".
5. Treat the mesh relay as one more source, not a replacement. Query the author's public write relays as well, or fall back to them on any error or timeout.

### Mesh relay policy

- A mesh relay SHOULD serve its owner's public events to anyone.
- It MUST NOT serve private data without NIP-42 authentication as a party to that data. Private data includes DMs, gift wraps, and any cache of what the owner reads or follows.
- It SHOULD refuse writes from unauthenticated mesh peers. It MAY accept events signed by its owner, or by authenticated users it chooses to accept.

## Media

### Listing a mesh Blossom server

The user adds a `server` tag to their `kind:10063`:

```json
{
  "kind": 10063,
  "content": "",
  "tags": [
    ["server", "https://blossom.example.com"],
    ["server", "https://cdn.example.net"],
    ["server", "fipsmesh://npub1xlrwmhu.../"]
  ]
}
```

1. A `fipsmesh` entry SHOULD come after the user's public servers. BUD-03 clients try servers in order, so clients without FIPS support lose nothing.
2. A user MUST NOT list a `fipsmesh` entry as their only server.
3. The entry SHOULD only be listed while the server is serving. A device that stops serving SHOULD publish a new `kind:10063` without it. That update can fail, so readers MUST treat a listed entry as a hint that may be out of date.
4. Uploads go to public servers as usual. The mesh server holds copies, from [BUD-04](https://github.com/hzrd149/blossom/blob/master/buds/04.md) mirroring or the owner's own uploads. Media URLs in notes SHOULD point at a public server.

Clients that don't support this NIP are expected to skip server entries they can't use.

### Blossom server requirements

The mesh server MUST support `GET /<sha256>` and `HEAD /<sha256>` from [BUD-01](https://github.com/hzrd149/blossom/blob/master/buds/01.md), with an optional file extension. It MAY support `Range` requests, but readers following this NIP don't send them.

It SHOULD expose only these two endpoints on the mesh unless every other endpoint has been reviewed under "Mesh peers are strangers".

To a mesh peer that has not authenticated as the owner, it SHOULD serve only blobs that the owner's public events name. Those are the blobs the owner has already published, such as photos in notes. A hash is not a secret, so files the owner keeps private (attachments in DMs or gift wraps, private storage) MUST NOT be readable by hash over the mesh. If the owner's other devices may upload over the mesh, the server MUST check the BUD-02 `kind:24242` signature before it reads or allocates the body.

### Reading a blob over the mesh

Given a media URL in an event by author `P`:

`P` is the author of the event being rendered. That is the note containing the URL, or the `kind:0` whose `picture` or `banner` it is. A client MUST NOT pick `P` any other way, such as from a table mapping blob hashes to whoever first referenced them. Otherwise anyone who reposts someone else's media URL could send other readers to their own node.

1. Take the SHA-256 from the URL path, as in [BUD-02](https://github.com/hzrd149/blossom/blob/master/buds/02.md): the last path segment is 64 hex characters, with an optional extension. If there isn't one, load the URL normally.
2. Get `P`'s `kind:10063` and verify it (see "Client behaviour"). Clients SHOULD look on `P`'s NIP-65 write relays, not only their own relays.
3. Take the first well-formed `fipsmesh` server entry. If there is none, or `P` doesn't pass the dialing rule in "Client behaviour", load the URL normally.
4. Connect to the mesh npub through FIPS.
5. Send `GET /<sha256>` to the node's mesh address on TCP port 80, with no `Range` header.
6. Accept only a `200` response. Any other status, including `206`, is a failure.
7. The client SHOULD cap how many bytes it reads, no higher than it would accept for the same media from a public server. If `Content-Length` is over the cap, or the body grows past it, the client MUST abort.
8. **The client MUST hash the full body and compare it with `<sha256>` before using any of it.** If they don't match, the client MUST discard the body and load the URL normally.
9. On any error, timeout or failure above, load the URL normally.

Clients SHOULD cache the blob under the original URL or its hash, never under a local proxy address. Clients MAY show where a blob came from, for example with a "via mesh" badge.

### Reading a blob in a web browser

A web page can follow the steps above without any browser support for FIPS. It runs a FIPS node in the page with a throwaway key, reaches the mesh through a FIPS node that accepts WebSocket connections (a seed), and sends the same `GET /<sha256>` over that session.

- The page shows the hash-checked bytes through a `blob:` URL (`URL.createObjectURL`). That URL is only the tab's local handle for bytes it already holds. It is not the blob's address. A client MUST NOT publish it, put it in an event, or cache under it. The blob's address stays the original URL and its hash.
- If a server prepares the page, it MAY look up the author's `kind:10063` for the page. It MUST verify it as in "Client behaviour" and MUST pick `P` by the author rule above. It SHOULD NOT keep a copy of the blob. The reader's browser does the read and the hash check.
- The seed sees the reader's IP address and that it talks to the mesh, as any server the page connects to would. The mesh node sees only the seed.

### Reading without revealing the reader

Dialling a node directly tells it the reader's network endpoints (see "Security and privacy"). A reader MAY instead reach the node through a seed, as a web page does. Then the node never learns the reader's endpoints, and the seed does. This is a FIPS routing choice and changes nothing above: the same request, the same hash check.

## Client behaviour

These rules apply to both relays and media:

- **Verify the list.** Before using a `kind:10002` or `kind:10063` to find a mesh node, a client MUST verify its signature and check that its `pubkey` is the author's. Any relay can send a forged list that points at a node it controls.
- **Who to dial.** By default, clients SHOULD only dial the mesh nodes of authors the reader follows, or trusts through their web of trust. Otherwise anyone whose note is shown can make the reader dial their node. Clients MAY let the user widen this.
- **Limits.** Clients SHOULD cap what they take from one mesh node: bytes per blob, and events and bytes per relay subscription.
- **Drop bad nodes.** If a mesh node breaks the rules (a body over the cap, a wrong hash, an event with a bad signature, or a stream past the limits), the client SHOULD stop asking that mesh npub for the rest of the session. That is not a passing network error.

- Clients SHOULD keep the wait for the mesh short (for example 5 s to connect), so an unreachable node doesn't slow anything down.
- Clients SHOULD remember for a short time (for example 30 s) that a mesh npub was unreachable, so a dead node costs one timeout rather than one per request.
- An implementation that exposes mesh connections to other software on the same device, such as a loopback proxy, SHOULD protect them with an unguessable token. Otherwise other apps could use the user's mesh connections.

## Serving from a phone

Serving SHOULD be off by default and turned on only by the user. On a battery-powered or metered device, the FIPS node SHOULD be set up so that it doesn't relay other nodes' traffic, and SHOULD cap its number of peers. The FIPS specification describes how.

## Security and privacy

- **Integrity** comes from signatures (notes) and the hash check (media), not from the transport.
- **Linkability:** a `fipsmesh` entry publicly links the user's Nostr identity to a mesh npub. Depending on the FIPS setup, that npub's discovery data can reveal the device's network endpoints, including LAN addresses. Removing the entry later does not undo this: older versions of a replaceable event can survive on relays and in archives. Users SHOULD be told this before they turn serving on.
- **Reader exposure:** dialling a mesh npub reveals the reader's own mesh endpoints to that node, just as connecting to any server reveals the reader's IP address.
- **Routing to the wrong node:** a reader that picked a node from anything other than the author of the event being rendered could be tricked. One note quoting a popular blob URL could make every reader dial an attacker's node. That would expose the readers' endpoints, and without the hash check it would let the attacker swap the media. The author rule under "Reading a blob over the mesh" prevents this.
- **Private data:** a device's relay often holds data meant only for its owner. "Mesh peers are strangers" and "Mesh relay policy" keep it private.
- **Forged lists:** a reader that trusts an unsigned or wrongly signed `kind:10063` or `kind:10002` can be sent to any node. The "Verify the list" rule in "Client behaviour" prevents this.
- **Who reads what:** even with correct lists, dialling a node tells its owner that this reader is reading this author's notes or media right now. The follows/web-of-trust default limits this to authors the reader already chose.
- **Resource use:** a hostile mesh service can send a huge or endless body or event stream. Size caps, timeouts and dropping nodes that break the rules bound this, for notes and media alike. In the other direction, a node serving from a phone can be drained by heavy readers, which the per-peer limits under "Mesh peers are strangers" address.

## Implementation status

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
