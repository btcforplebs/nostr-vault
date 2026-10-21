// The page's FIPS node: non-forwarding, first route via the public iris seeds over WSS, then WebRTC
// (offers accepted only from owners). Serves NIP-01 over TCP/FIPS on RELAY_SERVICE_PORT, and reads photos from the
// owners' vaults on mesh port 80 (blob-get.js).
// Runs on the main thread: WebRTC needs RTCPeerConnection, which workers don't have.
import { FipsNode, identityFromSecretKey, encodeNpub, toHex } from "@fips/core"
import { WebSocketTransport } from "@fips/transport-websocket"
import { WebRtcTransport } from "@fips/transport-webrtc"
import { isOwner, xOnly } from "./owners.js"
import { TcpFipsRelayServer, RELAY_SERVICE_PORT } from "./tcp-server.js"
import { MeshBlobClient } from "./blob-get.js"

export const PUBLIC_SEEDS = ["wss://fips1.iris.to/fips", "wss://fips2.iris.to/fips"]
const KEY_ITEM = "fips-relay-key"
const OWNER_DIAL_MS = 30_000

/** The relay's own FIPS identity (never the owner's key), kept on this device in the page's storage (src/page-storage.js). */
export async function loadRelayIdentity(storage) {
  let hex = storage.getItem(KEY_ITEM)
  if (!hex) {
    hex = toHex(crypto.getRandomValues(new Uint8Array(32)))
    storage.setItem(KEY_ITEM, hex)
  }
  return identityFromSecretKey(Uint8Array.from(hex.match(/../g), b => parseInt(b, 16)))
}

/**
 * @param haven      Haven's entry point handle (src/haven/haven.js), already started
 * @param getOwners  () => Set<x-only hex>
 * @param storage    the page's storage (src/page-storage.js), which holds the relay's FIPS key
 * @param onStatus   (status) => void, called on every change
 */
export async function startFipsRelay({ haven, getOwners, storage, onStatus = () => {}, seeds = PUBLIC_SEEDS }) {
  const identity = await loadRelayIdentity(storage)
  const status = { npub: encodeNpub(identity.xOnlyPubkey), seeds: new Map(), owners: new Map(), sessions: new Map(), server: undefined, errors: 0, lastError: "" }
  const emit = () => onStatus(status)

  const ws = new WebSocketTransport({ seedUrls: seeds })
  const rtc = new WebRtcTransport({
    acceptConnections: true,
    autoConnect: false,
    advertiseOnNostr: false,
    allowIncomingPeer: pk => isOwner(getOwners(), pk),
  })
  const node = new FipsNode({ identity, transports: [ws, rtc], forwarding: false })

  // Once an owner's session is up, ask its vault for a direct WebRTC link. The offer rides that session
  // (FSP port 257), and after it connects the 7447 stream no longer needs the seed. Retried on the dial
  // tick until it holds, so a dropped link or a vault without WebRTC costs one attempt per tick.
  const directing = new Set()
  // FIPS maps an x-only key to its canonical even-parity compressed form, hence "02".
  const goDirect = owner => node.connect({ transport: "webrtc", addr: "02" + owner })
  const upgradeOwners = () => {
    for (const owner of getOwners()) {
      const o = status.owners.get(owner)
      if (status.sessions.get(owner) !== "established" || directing.has(owner) || (o?.transport === "webrtc" && o.state === "connected")) continue
      directing.add(owner)
      goDirect(owner)
        .catch(e => { status.errors++; status.lastError = "direct to owner: " + String(e?.message ?? e).slice(0, 140); emit() })
        .finally(() => directing.delete(owner))
    }
  }
  node.on("peer", p => {
    const owner = isOwner(getOwners(), p.remotePubkey)
    if (p.remoteAddr?.transport === "websocket") status.seeds.set(p.remoteAddr.addr, p.state)
    if (owner) status.owners.set(xOnly(p.remotePubkey), { transport: p.remoteAddr?.transport, state: p.state, at: Date.now() })
    emit()
  })
  node.on("session", s => {
    if (isOwner(getOwners(), s.remotePubkey)) status.sessions.set(xOnly(s.remotePubkey), s.state)
    emit()
    upgradeOwners()
  })
  node.on("error", e => {
    status.errors++
    status.lastError = String(e?.err?.message ?? e).slice(0, 160)
    emit()
  })

  const server = new TcpFipsRelayServer(node, haven, getOwners)
  status.server = server.stats
  // Photos from the owners' vaults (GET /<sha256> on mesh port 80), over the same session as the 7447 stream.
  const blobs = new MeshBlobClient(node, identity.publicKey, { allow: k => isOwner(getOwners(), k) })
  status.blobs = blobs.stats
  await node.start()
  server.start()
  const statsTimer = setInterval(emit, 1000)
  // The page opens the FIPS session to each owner, not the other way round. A jmcorgan v0.5.2 vault
  // can't find or open a session to the page by itself: its lookups go to tree peers only, its native
  // API doesn't seed the identity cache the lookup proof is checked against, and a session it initiates
  // to fips-ts fails AEAD on the page ("invalid tag"). A page-initiated session is the G1-proven
  // direction. The vault's 7447 flow then rides it. An empty datagram to 7447 is not a TCP/FIPS segment
  // and is dropped there; it exists to open and keep the session.
  const dialOwners = () => {
    for (const owner of getOwners()) {
      node.sendDatagram({ dst: "02" + owner, srcPort: RELAY_SERVICE_PORT, dstPort: RELAY_SERVICE_PORT, payload: new Uint8Array(0) })
        .catch(e => { status.errors++; status.lastError = "dial owner: " + String(e?.message ?? e).slice(0, 140); emit() })
    }
  }
  dialOwners()
  const dialTimer = setInterval(() => { dialOwners(); upgradeOwners() }, OWNER_DIAL_MS)
  emit()

  return {
    node,
    server,
    status,
    /** Ask an owner's vault for a direct WebRTC link (needs an existing FIPS route, i.e. a session). */
    goDirect,
    /** A blob from an owner's vault by sha256: { bytes, type }, hash-checked. See blob-get.js. */
    getBlob: (vault, sha256, opts) => blobs.get(vault, sha256, opts),
    stop: async () => {
      clearInterval(statsTimer)
      clearInterval(dialTimer)
      await blobs.stop()
      await server.stop()
      await node.stop()
    },
  }
}

