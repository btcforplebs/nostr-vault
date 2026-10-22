> **Draft, not yet submitted.** This NIP has not been proposed to the [nostr-protocol/nips](https://github.com/nostr-protocol/nips) repository. It lives here while Nostr Vault builds against it, and it may change. How Nostr Vault implements it is in [NIP-F1-IMPLEMENTATION.md](NIP-F1-IMPLEMENTATION.md).

NIP-F1
======

Nostr over the FIPS Mesh
------------------------

`draft` `optional`

This NIP lets a user's own device act as one of their relays and one of their Blossom servers, even though it can only be reached over the [FIPS](https://github.com/jmcorgan/fips) mesh. It defines one address form, `fipsmesh://<npub>/`, and how clients use it to:

- read the user's notes from that device (the outbox model, [NIP-65](https://github.com/nostr-protocol/nips/blob/master/65.md)), and
- read the user's media from that device ([NIP-B7](https://github.com/nostr-protocol/nips/blob/master/B7.md) `kind:10063`, detailed in [BUD-03](https://github.com/hzrd149/blossom/blob/master/buds/03.md)).

With this, a phone or home computer can serve its owner's notes and media directly to other users. It doesn't need a public address, a domain name, or a third-party server. The NIP defines no new event kinds.

**Scope.** This NIP covers only Nostr data: entries in a user's existing lists (`kind:10002`, `kind:10063`), and how Nostr clients read notes and blobs from them. It does not specify FIPS. How a FIPS node is found, connected to, routed to and addressed is defined by the [FIPS specification](https://github.com/jmcorgan/fips). This NIP only refers to it, and holds whatever route FIPS takes.

## Motivation

On Nostr, notes are trusted because they are signed, and media is trusted because it is addressed by hash. Neither depends on which server delivered it. But every relay in a `kind:10002` and every server in a `kind:10063` must be reachable over the public internet. Most personal devices aren't: they sit behind NAT, change networks, and have no stable address.

FIPS is a mesh network where every node is identified by a Nostr key pair, and nodes find each other through Nostr relays. Any FIPS node can reach a device by its npub, from any network. This NIP lets such a device take part in the outbox model and in Blossom as an ordinary relay and server.

## Terms

- **Mesh node:** a FIPS node. Its identity is a secp256k1 key pair, written as an npub.
- **Mesh npub:** the npub of the mesh node that hosts the service. This SHOULD be a separate key from the user's Nostr identity key, so the user's main key never sits in a network daemon. The device SHOULD keep this key across restarts and only replace it when the user asks. A listed entry names the key, so a new key on every start would make every published list point at a node that no longer exists.
- **Mesh address:** the IPv6 address FIPS derives from a mesh npub (`fd00::/8`).
- **Mesh service:** a relay and/or Blossom server listening on its node's mesh address.
- **Owner:** the user whose list names the mesh service.

## The `fipsmesh` address

```
fipsmesh://<mesh-npub>/
```

It means "connect to this npub over FIPS, on TCP port 80."

- The authority is the bech32 `npub` of the mesh node. It has no port and no user info.
- The path MUST be `/`. The trailing slash is required: `fipsmesh://<npub>` without it is not well formed. Other paths are reserved for later use, and a client MUST ignore an address with any other path.
- A query string MAY follow the `/`. This NIP defines no parameters. A client MUST ignore query parameters it doesn't know, and MUST ignore any fragment.

A client MUST check that the address is well formed before using it, and MUST ignore any address that isn't. A client MUST NOT treat the npub as a DNS name, and MUST NOT turn the address into an `http(s)` or `ws(s)` URL on the public internet.

## Transport

The mesh service listens on **TCP port 80** at its mesh address. On that port it serves:

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

Anything the service would not give to an anonymous client on the public internet MUST NOT be given over the mesh without authentication. A peer is authenticated when it proves it holds a key the service accepts for that action:

- a Nostr key, through [NIP-42](https://github.com/nostr-protocol/nips/blob/master/42.md) for the relay or a BUD-02 `kind:24242` authorization for Blossom, or
- the peer's own mesh npub, which FIPS has already proven, if the owner has explicitly authorized that npub on this service, for example as one of the owner's own devices.

How the owner authorizes a mesh npub is up to the service. A service MUST NOT authorize a mesh npub because of anything it says about itself.

A service SHOULD limit how much one mesh peer can take, in requests and in bytes. It SHOULD stop serving, or ask its owner, once its total upload passes a limit the owner sets.

## Listing

A user MAY list any number of mesh services, for example one per device. Each entry stands alone: it names one mesh npub, and clients treat each entry as a separate relay or server.

A listed entry is a hint. The device may be off, offline, or gone, and the owner's attempt to remove an entry can fail. Clients MUST treat every entry as possibly out of date, and MUST use only the newest version of a list they have, as for any replaceable event.

The owner SHOULD remove an entry when its device stops serving for good, or when its mesh key is replaced.

A user MUST NOT list mesh services as their only relays or only Blossom servers. Notes and media have to stay reachable for clients without FIPS.

### Mesh relays in `kind:10002`

A mesh relay is listed with a `fipsmesh` tag in the user's `kind:10002`, next to the usual `r` tags:

```json
{
  "kind": 10002,
  "content": "",
  "tags": [
    ["r", "wss://relay.example.com"],
    ["r", "wss://nos.example.net", "write"],
    ["fipsmesh", "fipsmesh://npub1xlrwmhu.../", "write"]
  ]
}
```

- The second element is a `fipsmesh` address.
- The third element is a marker with the same meaning as in NIP-65. This NIP defines `write`: the user's notes can be read from this relay (an outbox). An entry with no marker means `write`. Clients MUST ignore entries with a marker they don't know. Other markers are reserved for later use.
- Clients MUST ignore any further elements they don't know.

A separate tag is used, not an `r` tag, so that clients without FIPS support never see the entry: unknown tags are ignored everywhere, but some clients try to connect to every `r` URL.

The user's client SHOULD publish each of the user's events to their mesh relays as well as to their public relays. Clients that pick a few relays from a user's list SHOULD NOT count a mesh relay as one of them.

### Mesh Blossom servers in `kind:10063`

A mesh Blossom server is listed as a `server` tag in the user's `kind:10063`:

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

- `fipsmesh` entries SHOULD come after the user's public servers. BUD-03 clients try servers in order, so clients without FIPS support lose nothing.
- Uploads go to public servers as usual. A mesh server holds copies, from [BUD-04](https://github.com/hzrd149/blossom/blob/master/buds/04.md) mirroring or the owner's own uploads. Media URLs in notes SHOULD point at a public server.

Clients that don't support this NIP are expected to skip server entries they can't use.

## Relays

### Reading notes over the mesh

1. Get the author's `kind:10002` and verify it (see "Client behaviour").
2. For each `fipsmesh` entry the client chooses to use, if the author passes the dialing rule in "Client behaviour", connect to the mesh npub through FIPS, as the FIPS specification describes.
3. Open a WebSocket to `/` on the node's mesh address, port 80, and send `REQ` as with any relay.
4. Verify every event's signature as usual. A mesh relay is trusted no more than any other relay. Drop any event not signed by the author, and apply the stream limits in "Client behaviour".
5. Treat a mesh relay as one more source, not a replacement. Query the author's public write relays as well, or fall back to them on any error or timeout.

### Mesh relay policy

- A mesh relay SHOULD serve its owner's public events to anyone.
- It MUST NOT serve private data except to a peer authenticated as a party to that data. Private data includes DMs, gift wraps, and any cache of what the owner reads or follows.
- It SHOULD refuse writes from unauthenticated mesh peers. It MAY accept events signed by its owner, or by authenticated users it chooses to accept.

## Media

### Blossom server requirements

A mesh server MUST support `GET /<sha256>` and `HEAD /<sha256>` from [BUD-01](https://github.com/hzrd149/blossom/blob/master/buds/01.md), with an optional file extension. It MAY support `Range` requests. It MAY offer other Blossom endpoints, such as uploads, under the rules in "Mesh peers are strangers".

To a mesh peer that is not authenticated as the owner, it SHOULD serve only blobs that the owner's public events name. Those are the blobs the owner has already published, such as photos in notes. A hash is not a secret, so files the owner keeps private (attachments in DMs or gift wraps, private storage) MUST NOT be readable by hash by anyone who isn't authenticated as a party to them. A server that accepts uploads over the mesh MUST check the authorization before it reads or allocates the body.

### Reading a blob over the mesh

Given a media URL in an event by author `P`:

`P` is the author of the event being rendered. That is the note containing the URL, or the `kind:0` whose `picture` or `banner` it is. A client MUST NOT pick `P` any other way, such as from a table mapping blob hashes to whoever first referenced them. Otherwise anyone who reposts someone else's media URL could send other readers to their own node.

1. Take the SHA-256 from the URL path, as in [BUD-02](https://github.com/hzrd149/blossom/blob/master/buds/02.md): the last path segment is 64 hex characters, with an optional extension. If there isn't one, load the URL normally.
2. Get `P`'s `kind:10063` and verify it (see "Client behaviour"). Clients SHOULD look on `P`'s NIP-65 write relays, not only their own relays.
3. Take the well-formed `fipsmesh` server entries, in list order. If there are none, or `P` doesn't pass the dialing rule in "Client behaviour", load the URL normally. A client MAY try more than one entry, one after another or at the same time.
4. Connect to the entry's mesh npub through FIPS.
5. Send `GET /<sha256>` to the node's mesh address on TCP port 80.
6. Without a `Range` header, accept only a `200` response. A client MAY fetch the blob in parts with `Range` requests, and then accepts only `206` responses for exactly the requested range. Any other status is a failure.
7. The client SHOULD cap how many bytes it reads, no higher than it would accept for the same media from a public server. If `Content-Length` is over the cap, or the body grows past it, the client MUST abort.
8. **The client MUST hash the complete blob and compare it with `<sha256>` before it shows, plays, stores or passes on any of it.** If they don't match, the client MUST discard it and load the URL normally. Parts fetched with `Range` are checked once the whole blob is put together.
9. On any error, timeout or failure above, try the next entry or load the URL normally.

Clients SHOULD cache the blob under the original URL or its hash, never under a local address that stands for it. Clients MAY show where a blob came from, for example with a "via mesh" badge.

### Reading in a web browser

A web page can follow the steps above. It may reach the mesh by any means it has: a FIPS node running in the page that connects through another FIPS node accepting browser connections, a browser capability for FIPS addresses (such as the one proposed in [#2469](https://github.com/nostr-protocol/nips/pull/2469)), or anything else FIPS allows. These rules hold for all of them:

- The page shows the hash-checked bytes through a local handle, such as a `blob:` URL (`URL.createObjectURL`). That handle is not the blob's address. A client MUST NOT publish it, put it in an event, or cache under it. The blob's address stays the original URL and its hash.
- If a server prepares the page, it MAY look up the author's `kind:10063` for the page. It MUST verify it as in "Client behaviour" and MUST pick `P` by the author rule above. It SHOULD NOT keep a copy of the blob. The reader's browser does the read and the hash check.
- Any node the page connects through sees the reader's IP address and that it talks to the mesh, as any server the page connects to would.

## Client behaviour

These rules apply to both relays and media:

- **Verify the list.** Before using a `kind:10002` or `kind:10063` to find a mesh node, a client MUST verify its signature and check that its `pubkey` is the author's. Any relay can send a forged list that points at a node it controls.
- **Who to dial.** By default, clients SHOULD only reach the mesh nodes of authors the reader follows, or trusts through their web of trust. Otherwise anyone whose note is shown can make the reader reach their node. Clients MAY let the user widen this.
- **Limits.** Clients SHOULD cap what they take from one mesh node: bytes per blob, and events and bytes per relay subscription.
- **Drop bad nodes.** If a mesh node breaks the rules (a body over the cap, a wrong hash, an event with a bad signature, or a stream past the limits), the client SHOULD stop asking that mesh npub for the rest of the session. That is not a passing network error.
- **Fail fast.** Clients SHOULD keep the wait for the mesh short, so an unreachable node doesn't slow anything down, and SHOULD remember for a short time that a mesh npub was unreachable, so a dead node costs one timeout rather than one per request.
- **Protect local access.** An implementation that exposes mesh connections to other software on the same device, such as a loopback proxy, SHOULD protect them with an unguessable token. Otherwise other apps could use the user's mesh connections.

How a client reaches a mesh npub (directly, through other FIPS nodes, over a kept connection, with which key of its own) is a FIPS choice. It changes nothing in this NIP: the same request, the same checks.

## Serving from a battery-powered device

Serving SHOULD be off by default and turned on only by the user. On a battery-powered or metered device, the FIPS node SHOULD be set up so that it doesn't relay other nodes' traffic, and SHOULD cap its number of peers. The FIPS specification describes how. Before serving starts, the user SHOULD be told what "Linkability" below means for them.

## Extending this NIP

So that later features don't need changes to these rules:

- **New parameters** go in the address query string, and only if a client that ignores them still reaches a correct service and reads correct data. A change that would make an old client connect to the wrong place or misread a response MUST use a new scheme instead.
- **New entry types** use new tag markers in `kind:10002`, or new tags. Clients ignore what they don't know.
- **New capabilities** of a mesh service (more Blossom endpoints, more relay features) are found by asking the service, as with any relay or server. A client MUST treat an unsupported request like any other failure and fall back.
- **Routing, discovery and keys** belong to FIPS. Nothing here depends on which FIPS nodes carry the traffic, or who runs them.

## Security and privacy

- **Integrity** comes from signatures (notes) and the hash check (media), not from the transport. A lost or stolen device holds only its mesh key, which can't sign the owner's notes. At worst it serves stale data or nothing, until the owner removes its entry.
- **Linkability:** a `fipsmesh` entry publicly links the user's Nostr identity to a mesh npub. Depending on the FIPS setup, that npub's discovery data can reveal the device's network endpoints, including LAN addresses. Removing the entry later does not undo this: older versions of a replaceable event can survive on relays and in archives.
- **Reader exposure:** reaching a mesh npub directly reveals the reader's own mesh endpoints to that node, just as connecting to any server reveals the reader's IP address. A reader MAY reach the node through other FIPS nodes instead, so the node never learns the reader's endpoints and those nodes do.
- **Routing to the wrong node:** a reader that picked a node from anything other than the author of the event being rendered could be tricked. One note quoting a popular blob URL could make every reader reach an attacker's node. That would expose the readers' endpoints, and without the hash check it would let the attacker swap the media. The author rule under "Reading a blob over the mesh" prevents this.
- **Private data:** a device's relay often holds data meant only for its owner. "Mesh peers are strangers" and "Mesh relay policy" keep it private.
- **Forged lists:** a reader that trusts an unsigned or wrongly signed `kind:10063` or `kind:10002` can be sent to any node. The "Verify the list" rule in "Client behaviour" prevents this.
- **Who reads what:** even with correct lists, reaching a node tells its owner that this reader is reading this author's notes or media right now. The follows/web-of-trust default limits this to authors the reader already chose.
- **Resource use:** a hostile mesh service can send a huge or endless body or event stream. Size caps, timeouts and dropping nodes that break the rules bound this, for notes and media alike. In the other direction, a device serving its owner's data can be drained by heavy readers, which the per-peer limits under "Mesh peers are strangers" address.
