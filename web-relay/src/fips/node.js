// The page's FIPS node: non-forwarding, first route via the public iris seeds over WSS, then WebRTC
// (offers accepted only from owners). Serves NIP-01 over TCP/FIPS on RELAY_SERVICE_PORT.
// Runs on the main thread: WebRTC needs RTCPeerConnection, which workers don't have.
import { FipsNode, identityFromSecretKey, encodeNpub, toHex } from "@fips/core"
import { WebSocketTransport } from "@fips/transport-websocket"
import { WebRtcTransport } from "@fips/transport-webrtc"
import { isOwner, xOnly } from "./owners.js"
import { TcpFipsRelayServer } from "./tcp-server.js"

export const PUBLIC_SEEDS = ["wss://fips1.iris.to/fips", "wss://fips2.iris.to/fips"]
const KEY_ITEM = "fips-relay-key"

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
