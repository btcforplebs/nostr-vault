// The page's FIPS node: non-forwarding, first route via the public iris seeds over WSS, then WebRTC
// (offers accepted only from owners). Serves NIP-01 over TCP/FIPS on RELAY_SERVICE_PORT.
// Runs on the main thread: WebRTC needs RTCPeerConnection, which workers don't have.
import { FipsNode, identityFromSecretKey, encodeNpub, toHex } from "@fips/core"
import { WebSocketTransport } from "@fips/transport-websocket"
import { WebRtcTransport } from "@fips/transport-webrtc"
import { isOwner, xOnly } from "./owners.js"
import { TcpFipsRelayServer, RELAY_SERVICE_PORT } from "./tcp-server.js"

export const PUBLIC_SEEDS = ["wss://fips1.iris.to/fips", "wss://fips2.iris.to/fips"]
const KEY_ITEM = "fips-relay-key"
const OWNER_DIAL_MS = 30_000

/** The relay's own FIPS identity (never the owner's key), kept on this device. */
export async function loadRelayIdentity(storage = localStorage) {
  let hex = storage.getItem(KEY_ITEM)
  if (!hex) {
    hex = toHex(crypto.getRandomValues(new Uint8Array(32)))
    storage.setItem(KEY_ITEM, hex)
  }
  return identityFromSecretKey(Uint8Array.from(hex.match(/../g), b => parseInt(b, 16)))
}

/**
 * @param store      { event, query, count } over the worker relay
 * @param getOwners  () => Set<x-only hex>
 * @param onStatus   (status) => void, called on every change
 */
export async function startFipsRelay({ store, getOwners, onStatus = () => {}, seeds = PUBLIC_SEEDS }) {
  const identity = await loadRelayIdentity()
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

  node.on("peer", p => {
    const owner = isOwner(getOwners(), p.remotePubkey)
    if (p.remoteAddr?.transport === "websocket") status.seeds.set(p.remoteAddr.addr, p.state)
    if (owner) status.owners.set(xOnly(p.remotePubkey), { transport: p.remoteAddr?.transport, state: p.state, at: Date.now() })
    emit()
  })
  node.on("session", s => {
    if (isOwner(getOwners(), s.remotePubkey)) status.sessions.set(xOnly(s.remotePubkey), s.state)
    emit()
  })
  node.on("error", e => {
    status.errors++
    status.lastError = String(e?.err?.message ?? e).slice(0, 160)
    emit()
  })

  const server = new TcpFipsRelayServer(node, store, getOwners)
  status.server = server.stats
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
  const dialTimer = setInterval(dialOwners, OWNER_DIAL_MS)
  emit()

  return {
    node,
    server,
    status,
    /** Ask an owner's vault for a direct WebRTC link (needs an existing FIPS route, i.e. a session). */
    // FIPS maps an x-only key to its canonical even-parity compressed form, hence "02".
    goDirect: owner => node.connect({ transport: "webrtc", addr: "02" + owner }),
    stop: async () => {
      clearInterval(statsTimer)
      clearInterval(dialTimer)
      await server.stop()
      await node.stop()
    },
  }
}

/** NIP-01 store over the worker relay. */
export function workerRelayStore(relay) {
  let n = 0
  return {
    event: async ev => relay.event(ev),
    query: filters => relay.query(["REQ", `fips-${++n}`, ...filters]),
    count: filters => relay.count(["REQ", `fips-${++n}`, ...filters]),
  }
}
