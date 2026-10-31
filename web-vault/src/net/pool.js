// The network side: nostr-tools SimplePool to the user's relays. The UI never renders from here directly;
// what comes in is written to the in-page Haven and read back from it.
import { SimplePool } from "nostr-tools/pool"
import { normalizeURL } from "nostr-tools/utils"
import { blocklist } from "./never-connect.js"
import { relayBudget } from "./relay-budget.js"

// Hosts the iPhone app strips from saved lists because they stopped answering (HavenConfig.deadRelayHosts).
export const DEAD_RELAY_HOSTS = new Set(["nos.lol", "nostr.mom", "offchain.pub"])

const hostOf = url => { try { return new URL(url).hostname.toLowerCase() } catch { return "" } }
export const isDead = url => DEAD_RELAY_HOSTS.has(hostOf(url))

// Every read, query and publish opens its relays through ensureRelay, so a dead host is refused here and its
// subscription closes at once instead of holding querySync to its timeout (primal alone 541 ms, + nos.lol 5,002 ms).
// A signer's own relay is the exception: the user's bunker answers only there, so a bunker on nos.lol must still
// connect (it failed in 11 ms as "check your connection" while nos.lol was up).
//
// Brave Shields cap a tab at 30 open WebSockets and fail the rest at once (measured 2026-10-25), so a
// relay past the cap would drop silently. Before a new relay opens, the pool keeps itself under MAX_OPEN_RELAYS:
// it closes the relay that has sat idle longest (nothing open on it). A socket the pool has closed still counts
// until the browser finishes closing it (a 15-profile hop had 24 relays plus 7 sockets still CLOSING).
// When every relay is busy, Brave waits SLOT_WAIT_MS for one to free up, then skips the relay: it would fail there
// anyway. Waiting longer costs more than it saves: querySync holds all its relays until every one has opened, so a
// relay waiting for a slot keeps the others busy too (1 s halved the notes a profile hop showed). Other browsers
// have no such cap and open it at once, as before.
export const MAX_OPEN_RELAYS = 24
const SLOT_WAIT_MS = 500
// Idle means nothing open on the relay. Not nostr-tools' ongoingOperations/idleSince: a subscription closed twice
// counts down twice, the count goes negative (-37 on relay.damus.io after a profile hop), idleSince is then never
// set again, and that relay never idles out, by nostr-tools' own idle timer or by this cap.
const busy = r => r.openSubs.size > 0 || r.openEventPublishes.size > 0 || r.openCountRequests.size > 0
// A relay that has just connected has no subscription on it yet; don't close it under the caller about to use it.
const IDLE_GRACE_MS = 250
const SLOT_POLL_MS = 50
// nostr-tools' keep-alive ping is a dummy REQ every 29 s on every open relay (browsers have no WebSocket ping), which
// was half of what an open tab sent damus. A relay heard from within the last ping interval is plainly alive, so it is
// not pinged; in a hidden tab, not until it has been quiet for HIDDEN_PING_MS.
export const HIDDEN_PING_MS = 5 * 60_000

export class LivePool extends SimplePool {
  signerRelays = new Set()
  maxOpenRelays = MAX_OPEN_RELAYS
  strictCap = !!globalThis.navigator?.brave // Brave: never open past the cap
  lastUsed = new WeakMap()
  closing = new Set() // sockets of relays that closed or failed, until they reach CLOSED
  watched = new WeakSet()
  neverConnect = blocklist([])
  budget = relayBudget() // relay-budget.js: hosts that ban busy addresses get a minute's and a day's share
  heard = new WeakMap() // socket -> when it last sent us anything
  isHidden = () => globalThis.document?.visibilityState === "hidden"
  /** Relays a signer (a bunker link) named: neither the dead list nor Never Connect refuses these. */
  keepForSigner(urls) { for (const u of urls ?? []) try { this.signerRelays.add(normalizeURL(u)) } catch {} }
  /** The user's Never Connect list (kind 10006, never-connect.js): refused from now on, and closed if open. */
  setNeverConnect(urls) {
    this.neverConnect = blocklist(urls)
    for (const [key, r] of this.relays) {
      if (!this.neverConnect(key) || this.signerRelays.has(key)) continue
      this.relays.delete(key)
      r.close()
    }
  }
  async ensureRelay(url, params) {
    const key = normalizeURL(url)
    if (isDead(url) && !this.signerRelays.has(key)) throw new Error(`dead relay skipped: ${url}`)
    if (this.neverConnect(url) && !this.signerRelays.has(key)) throw new Error(`on your Never Connect list: ${url}`)
    if (!this.signerRelays.has(key) && !this.budget.take(url)) throw new Error(`relay skipped, request budget used: ${url}`)
    const deadline = Date.now() + (this.strictCap ? SLOT_WAIT_MS : 0)
    // Nothing is awaited between the last check and super.ensureRelay, which adds the relay to this.relays
    // synchronously, so relays opening at the same moment can't all take the same free slot.
    while (!this.relays.has(key) && !this.makeRoom()) {
      if (Date.now() >= deadline) {
        if (this.strictCap) throw new Error(`relay skipped, ${this.maxOpenRelays} sockets busy: ${url}`)
        break
      }
      await new Promise(r => setTimeout(r, SLOT_POLL_MS))
    }
    const opening = super.ensureRelay(url, params), fresh = this.relays.get(key)
    if (fresh) { this.watch(fresh); this.lastUsed.set(fresh, Date.now()) }
    const relay = await opening
    this.lastUsed.set(relay, Date.now())
    this.listen(relay)
    return relay
  }
  /** Keeps each socket a relay closes (by us, by its idle timer, or on a failed connect) in `closing`. */
  watch(r) {
    if (!r || this.watched.has(r)) return
    this.watched.add(r)
    const keep = () => { if (r.ws && r.ws.readyState !== 3) this.closing.add(r.ws) }
    const close = r.close.bind(r), hardClose = r.handleHardClose.bind(r)
    r.close = () => { keep(); close() }
    r.handleHardClose = reason => { keep(); hardClose(reason) }
    const ping = r.pingpong.bind(r)
    r.pingpong = () => {
      this.listen(r)
      const quiet = Date.now() - (this.heard.get(r.ws) ?? 0)
      if (quiet < (this.isHidden() ? HIDDEN_PING_MS : r.pingFrequency)) return
      if (!this.budget.take(r.url)) return
      return ping()
    }
  }
  /** Notes when the relay's current socket last sent anything (a reconnect brings a new socket). */
  listen(r) {
    const ws = r?.ws
    if (!ws || this.heard.has(ws)) return
    this.heard.set(ws, Date.now())
    const on = ws.onmessage
    ws.onmessage = ev => { this.heard.set(ws, Date.now()); return on?.call(ws, ev) }
  }
  /** Relays plus sockets the browser is still closing: what counts against Brave's cap. */
  openSockets() {
    for (const ws of this.closing) if (ws.readyState === 3) this.closing.delete(ws)
    return this.relays.size + this.closing.size
  }
  /** Closes the least recently used idle relays until a new one fits under the cap. -> whether one fits now. */
  makeRoom() {
    if (this.openSockets() < this.maxOpenRelays) return true
    const now = Date.now(), idle = []
    for (const [url, r] of this.relays) {
      if (busy(r) || this.signerRelays.has(url)) continue
      if (r.connected) {
        const since = this.lastUsed.get(r) || 0
        if (now - since >= IDLE_GRACE_MS) idle.push([since, url, r])
      } else if (!r.connectionPromise) idle.push([0, url, r]) // dropped, waiting to reconnect with nothing to resend
    }
    idle.sort((a, b) => a[0] - b[0])
    // Stop once the relays alone fit: a closed relay's socket moves to `closing`, and closing more would only
    // drop relays that are still useful while the browser finishes.
    for (const [, url, r] of idle) {
      if (this.relays.size < this.maxOpenRelays) break
      this.relays.delete(url)
      r.close()
    }
    return this.openSockets() < this.maxOpenRelays
  }
}

export const pool = new LivePool({ enablePing: true, enableReconnect: true })

export const DEFAULT_RELAYS = ["wss://relay.damus.io", "wss://relay.primal.net"]
// relay.nostr.band stopped answering (no EOSE, every query held to its timeout) on 2026-10-13.
export const PROFILE_RELAYS = ["wss://purplepag.es"]

/** Read and write relays from a kind 10002 event (NIP-65), dead hosts dropped, falling back to the defaults. */
export function relayLists(ev) {
  const read = [], write = []
  for (const t of ev?.tags ?? []) {
    if (t[0] !== "r" || !/^wss?:\/\//.test(t[1] ?? "")) continue
    const url = t[1].replace(/\/+$/, "")
    if (isDead(url)) continue
    if (t[2] !== "write") read.push(url)
    if (t[2] !== "read") write.push(url)
  }
  return { read: read.length ? read : DEFAULT_RELAYS, write: write.length ? write : DEFAULT_RELAYS }
}

export const uniq = a => [...new Set(a)]

// Where the iPhone app sends a new note: its Write list, or this list when that is empty
// (HavenConfig.fallbackWriteRelays / RelayConfiguration.directBroadcastRelays).
export const BROADCAST_RELAYS = ["wss://relay.btcforplebs.com", "wss://relay.damus.io", "wss://relay.snort.social"]
const loopbackHost = h => { h = h.replace(/^\[|\]$/g, "").toLowerCase(); return h === "localhost" || h === "::1" || /^127\./.test(h) }
/** A relay on the machine the browser runs on (the Mac's own vault relay, ws://localhost:3355). */
export const isLoopback = url => loopbackHost(hostOf(url))

/**
 * The relays a new note goes to: the write list plus the iPhone app's broadcast set, so a short or half-dead
 * write list still reaches the wider network. Dead hosts are dropped as the iPhone app drops them. A loopback
 * relay is only reachable from a page open on that same machine, so it is kept only there and marked local.
 * -> { network: [url], local: [url] }
 */
export function publishRelays(writeRelays, pageHost = globalThis.location?.hostname ?? "") {
  const urls = uniq([...writeRelays, ...BROADCAST_RELAYS].map(u => u.trim().replace(/\/+$/, "")).filter(u => /^wss?:\/\//.test(u)))
  const live = urls.filter(u => !isDead(u))
  return { network: live.filter(u => !isLoopback(u)), local: loopbackHost(pageHost) ? live.filter(isLoopback) : [] }
}
