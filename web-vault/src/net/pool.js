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
// A reconnect the pool makes itself gives up on the handshake after this and tries again, like the callers' opens.
const RETRY_CONNECT_TIMEOUT_MS = 5000
// A one-shot ask (querySync, subscribeEose) waits at most this long for a relay that hasn't connected yet, then
// goes on without it; the connect itself carries on to its own timeout, so the relay is there for the next ask if it
// does open. querySync answers only when every relay has answered or timed out, so one relay that accepts TCP and
// never finishes the handshake held every quote to the 5 s connect timeout: nostr-pub.wellorder.net, 4,064-5,009 ms
// with it and 722-792 ms without (Tron, RESEARCH/NV_WEB_SLOW_LOAD_2026_11_12.md). Live subscriptions still wait
// the full connect: a slow relay they skipped would be missing from the feed until every relay had dropped.
// The cap skips a relay only once another relay of the same ask is open: an ask whose relays are all still connecting
// (a cold load on a slow link) waits for the first of them, so it never ends with every relay skipped and nothing read.
// A DM destination lookup that came back empty sent to the fallback (the sender's own relays) for 10 min (Tron).
export const QUICK_CONNECT_MS = 1500
// A relay whose connect failed or timed out is skipped by fresh opens for a cool-down, doubling per failure in a row
// up to the last step, and asked again after it (or at once when the browser comes back online). It was re-tried
// on every query: 13-17 failed sockets to wellorder in 30-45 s. Writes don't wait on it: a publish dials the relay
// anyway (a relay back up takes the user's note at once, and its connect ends the cool-down).
export const COOL_DOWN_MS = [60e3, 120e3, 300e3, 600e3]

/** One ask spread over several one-shot reads (a sync that asks each relay on its own): pass it as `ask` to each
 *  querySync, so a slow relay is skipped once any relay of the whole sync is open, not only one of its own read. */
export const oneAsk = () => ({ open: 0, onOpen: new Set() })

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
  // A relay nostr-tools reconnects by itself is charged and gated in watch(); one the gates refuse waits here for
  // its next try. Keyed by normalizeURL, cleared when the relay is dropped, closed or reconnects.
  retryTimers = new Map() // url -> timeout
  retryCounts = new Map() // url -> attempts, for the backoff
  rawConnect = new WeakMap() // relay -> its own connect, before watch() wrapped it
  coolDowns = new Map() // url -> { until, n }: fresh opens skip it until then (connect failed or timed out n times in a row)
  quickConnectMs = QUICK_CONNECT_MS
  quickOpen = null // the open one-shot ask ({ open, onOpen }) while subscribeMap opens its relays, read synchronously by ensureRelay
  writeOpen = false // set while publish opens its relays, read synchronously by ensureRelay
  isHidden = () => globalThis.document?.visibilityState === "hidden"
  isOffline = () => globalThis.navigator?.onLine === false
  pageProtocol = () => globalThis.location?.protocol ?? ""
  /**
   * [10, 10, 10, 20, 20, 30, 60] s: the backoff nostr-tools used for its own reconnects (abstract-relay.js:116), so
   * a reconnect the gates refuse is retried by the pool on the same schedule instead of being dropped.
   */
  static RECONNECT_BACKOFF = [10e3, 10e3, 10e3, 20e3, 20e3, 30e3, 60e3]

  constructor(opts) {
    super(opts)
    // Back from sleep, or wifi again after a dead patch: try the relays that were waiting out a backoff at once
    // instead of up to a minute later. `online` is the only signal a browser gives; while offline nothing is tried
    // at all (attemptReconnect leaves it to this event), so a flapping link spends no budget on connects that can't open.
    this.onOnline = () => { this.coolDowns.clear(); this.retryAllNow() }
    globalThis.addEventListener?.("online", this.onOnline)
  }

  destroy() {
    globalThis.removeEventListener?.("online", this.onOnline)
    for (const t of this.retryTimers.values()) clearTimeout(t)
    this.retryTimers.clear()
    this.retryCounts.clear()
    this.coolDowns.clear()
    // nostr-tools holds its own 10-60 s reconnect timer per dropped relay (abstract-relay.js:187): a destroyed pool
    // must not leave those to open sockets after it is gone.
    for (const r of this.relays.values()) {
      if (r.reconnectTimeoutHandle) clearTimeout(r.reconnectTimeoutHandle)
      r.reconnectTimeoutHandle = undefined
    }
    super.destroy()
  }

  /** Relays a signer (a bunker link) named: neither the dead list nor Never Connect refuses these. */
  keepForSigner(urls) { for (const u of urls ?? []) try { this.signerRelays.add(normalizeURL(u)) } catch {} }
  /** The user's Never Connect list (kind 10006, never-connect.js): refused from now on, and closed if open. */
  setNeverConnect(urls) {
    this.neverConnect = blocklist(urls)
    for (const [key, r] of this.relays) {
      if (!this.neverConnect(key) || this.signerRelays.has(key)) continue
      this.relays.delete(key)
      this.forgetReconnect(key)
      r.close()
    }
  }
  /**
   * Every gate an open goes through: the dead list, Never Connect, a plain `ws://` on an https page, and the budget.
   * `n` is what the open will send (one REQ for a fresh relay, one per open subscription for a reconnect that
   * re-fires them). A signer's own relay is exempt from the lists and the budget, but not from the plain-ws rule.
   * -> null when it may go, else the refusal message.
   */
  refuse(url, n = 1, where = "request") {
    const signer = this.signerRelays.has(normalizeURL(url))
    if (isDead(url) && !signer) return `dead relay skipped: ${url}`
    if (this.neverConnect(url) && !signer) return `on your Never Connect list: ${url}`
    if (blockedPlain(url, this.pageProtocol())) return `plain ws:// relay skipped on an https page: ${url}`
    if (!signer && !this.budget.takeMany(url, n)) return `relay skipped, ${where} budget used: ${url}`
    return null
  }
  /**
   * querySync, plus `params.first(ev)`: when it is true for an event the read ends there with what has come in so far,
   * instead of waiting for every relay (a quote by id needs one verified copy). Without it, as nostr-tools'.
   */
  querySync(relays, filter, params) {
    const first = params?.first
    if (!first) return super.querySync(relays, filter, params)
    return new Promise(resolve => {
      const events = []
      let done = false, sub = null, found = false
      const finish = () => { if (done) return; done = true; resolve(events); if (found) sub?.close("found") }
      sub = this.subscribeEose(relays, filter, {
        ...params,
        first: undefined,
        onevent(ev) { if (done) return; events.push(ev); if (first(ev)) { found = true; finish() } },
        onclose: finish,
      })
    })
  }
  /** querySync and the other one-shot asks come through here; their opens wait at most quickConnectMs, unless the
   *  caller passes quickConnect: false (a lookup that picks where something goes must hear every relay). */
  subscribeEose(relays, filter, params) {
    return super.subscribeEose(relays, filter, { ...params, quickConnect: params?.quickConnect ?? true })
  }
  subscribeMap(requests, params) {
    // nostr-tools calls ensureRelay for every relay synchronously inside subscribeMap (each async opener runs up to
    // its first await, which is that call), so the flag is seen by exactly this ask's opens.
    const was = this.quickOpen
    this.quickOpen = params?.quickConnect ? (params.ask ?? oneAsk()) : null
    try { return super.subscribeMap(requests, params) } finally { this.quickOpen = was }
  }
  publish(relays, event, params) {
    // nostr-tools calls ensureRelay synchronously for each relay here too (only allowConnectingToRelay before it).
    const was = this.writeOpen
    this.writeOpen = true
    try { return super.publish(relays, event, params) } finally { this.writeOpen = was }
  }
  /** Still cooling down after a failed connect? A signer's relay never is. */
  coolingDown(key) {
    const c = this.coolDowns.get(key)
    return !!c && Date.now() < c.until && !this.signerRelays.has(key)
  }
  coolDown(key) {
    const n = (this.coolDowns.get(key)?.n ?? 0) + 1
    this.coolDowns.set(key, { n, until: Date.now() + COOL_DOWN_MS[Math.min(n - 1, COOL_DOWN_MS.length - 1)] })
  }
  async ensureRelay(url, params) {
    const ask = this.quickOpen, write = this.writeOpen // before any await: see subscribeMap and publish
    const key = normalizeURL(url)
    const held = this.relays.get(key)
    // Counted at once, so the ask's other relays (opened in this same tick) know one is already there.
    if (ask && held?.connected) ask.open++
    // A relay nostr-tools is reconnecting by itself is gated in watch(), which charges what that reconnect re-fires.
    // Taking a unit here too would spend two on one open.
    if (!(held && held.reconnectAttempts > 0)) {
      if (!held?.connected && !write && this.coolingDown(key)) throw new Error(`relay skipped, its last connect failed: ${url}`)
      const no = this.refuse(url, 1)
      if (no) throw new Error(no)
    }
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
    const wasOpen = !!this.relays.get(key)?.connected
    const opening = super.ensureRelay(url, params), fresh = this.relays.get(key)
    if (fresh) { this.watch(fresh); this.lastUsed.set(fresh, Date.now()) }
    // A connect that fails or times out (not one the gates refused) starts the relay's cool-down; one that opens ends it.
    opening.then(() => this.coolDowns.delete(key), err => { if (!err?.refused && !params?.abort?.aborted) this.coolDown(key) })
    let relay
    try {
      if (ask && !wasOpen) {
        // Skipped after quickConnectMs only if another relay of this ask is open by then, else as soon as one opens.
        let timer, waiting = null
        const slow = new Promise((_, reject) => {
          const skip = () => reject(new Error(`relay slow to connect, skipped for this ask: ${url}`))
          timer = setTimeout(() => {
            if (ask.open > 0) return skip()
            waiting = () => { if (ask.open > 0) skip() }
            ask.onOpen.add(waiting)
          }, this.quickConnectMs)
        })
        try {
          relay = await Promise.race([opening, slow])
          ask.open++
          for (const cb of [...ask.onOpen]) cb()
        } finally { clearTimeout(timer); if (waiting) ask.onOpen.delete(waiting) }
      } else relay = await opening
    } catch (err) {
      // super.ensureRelay drops a relay whose connect threw. A refusal from watch() must not: the feed, DM and
      // notification subscriptions are still open on that relay and would be orphaned, so keep it for the retry.
      if (err?.refused && held && !this.relays.has(key)) this.relays.set(key, held)
      throw err
    }
    this.retryCounts.delete(key)
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
    // A relay the pool closes on purpose is not coming back, so a retry waiting for it would only fire into nothing.
    r.close = () => { keep(); this.forgetReconnect(normalizeURL(r.url)); close() }
    r.handleHardClose = reason => { keep(); hardClose(reason) }
    // nostr-tools reconnects by itself (abstract-relay.js:184-192) and re-fires every open REQ on the new socket
    // (:251-262) without passing ensureRelay, so none of the gates above ever saw a reconnect. Charge what it will
    // send and refuse what the gates would have refused; a refused one is retried by retryReconnect, never dropped.
    const key = normalizeURL(r.url), connect = r.connect.bind(r)
    this.rawConnect.set(r, connect)
    r.connect = async opts => {
      // reconnectAttempts is the reliable signal: nostr-tools sets it in reconnect() before scheduling connect() and
      // resets it in the socket's onopen. A first connect has it at 0. An open already in flight is already paid for.
      const reconnecting = r.reconnectAttempts > 0 && !r.connectionPromise
      if (reconnecting) {
        const no = this.refuse(r.url, Math.max(1, r.openSubs.size), "reconnect")
        if (no) {
          // Take over the retry: nostr-tools' own timer would try again outside the gates' accounting, and its
          // reconnect() does not reschedule after a refused connect, so nothing else is coming.
          if (r.reconnectTimeoutHandle) { clearTimeout(r.reconnectTimeoutHandle); r.reconnectTimeoutHandle = undefined }
          this.retryReconnect(r)
          const err = new Error(no)
          err.refused = true
          throw err
        }
      }
      const relay = await connect(opts)
      if (reconnecting) this.retryCounts.delete(key)
      return relay
    }
    const ping = r.pingpong.bind(r)
    r.pingpong = () => {
      this.listen(r)
      const quiet = Date.now() - (this.heard.get(r.ws) ?? 0)
      if (quiet < (this.isHidden() ? HIDDEN_PING_MS : r.pingFrequency)) return
      if (!this.budget.take(r.url)) return
      return ping()
    }
  }
  /** Try a refused (or offline-parked) reconnect now, if the gates pass. Never throws: the relay stays in the pool. */
  attemptReconnect(r) {
    const key = normalizeURL(r.url)
    if (this.relays.get(key) !== r) return // dropped, replaced or closed meanwhile: nothing left to reconnect
    const connect = this.rawConnect.get(r)
    if (!connect) return
    // Offline: `online` calls retryAllNow, so waiting costs nothing and a connect that can't open spends no budget.
    if (this.isOffline()) { this.retryReconnect(r); return }
    const no = this.refuse(r.url, Math.max(1, r.openSubs.size), "reconnect")
    if (no) { this.retryReconnect(r); return }
    try {
      // A timeout, or a relay that black-holes the handshake holds connectionPromise forever and is never retried.
      connect({ timeout: RETRY_CONNECT_TIMEOUT_MS }).then(() => this.retryCounts.delete(key), () => {})
    } catch { this.retryReconnect(r) }
  }
  /** Retry a reconnect the gates refused, after the backoff nostr-tools used. One timer per relay. */
  retryReconnect(r) {
    const key = normalizeURL(r.url)
    if (this.retryTimers.has(key)) return
    const n = (this.retryCounts.get(key) ?? 0) + 1
    this.retryCounts.set(key, n)
    const backoff = LivePool.RECONNECT_BACKOFF
    const t = setTimeout(() => { this.retryTimers.delete(key); this.attemptReconnect(r) }, backoff[Math.min(n - 1, backoff.length - 1)])
    t?.unref?.() // node (the tests) only
    this.retryTimers.set(key, t)
  }
  /** Back online: every relay waiting out a backoff (or parked while offline) is tried at once, gates first. */
  retryAllNow() {
    for (const r of this.relays.values()) {
      if (r.connected || r.connectionPromise) continue
      const key = normalizeURL(r.url)
      const t = this.retryTimers.get(key)
      if (t) clearTimeout(t)
      this.retryTimers.delete(key)
      this.retryCounts.delete(key)
      this.attemptReconnect(r)
    }
  }
  forgetReconnect(key) {
    const t = this.retryTimers.get(key)
    if (t) clearTimeout(t)
    this.retryTimers.delete(key)
    this.retryCounts.delete(key)
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
      this.forgetReconnect(url)
      r.close()
    }
    return this.openSockets() < this.maxOpenRelays
  }
}

export const pool = new LivePool({ enablePing: true, enableReconnect: true })

// The apps' read set (iPhone/Mac and Android, Logen 2026-10-31), and a new account's starter list. Without
// nostr-pub.wellorder.net since 2026-11-12: it hangs the handshake 10-12 s or answers 503 (Tron's slow-load review).
export const DEFAULT_RELAYS = ["wss://relay.primal.net", "wss://relay.damus.io", "wss://relay.snort.social", "wss://relay.btcforplebs.com"]
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
  // `listed`: only the relays the 10002 names, never the defaults. With no 10002 it is empty: the user's own relays
  // aren't known, so the defaults (used to read and write meanwhile) must not stand in for them when deciding whether
  // a list is known (list-edit.js latestList, follows.js setFollow). Write relays only, as iOS (NostrService
  // ownListRelays): under NIP-65 your own lists live on your write (outbox) relays, so a read-only inbox relay that
  // never holds them must not count toward the majority (Tron #1464).
  return { read: read.length ? read : DEFAULT_RELAYS, write: write.length ? write : DEFAULT_RELAYS, listed: uniq(write) }
}

export const uniq = a => [...new Set(a)]

// The iPhone app's old broadcast set (HavenConfig.fallbackWriteRelays / RelayConfiguration.directBroadcastRelays).
// Since Logen's rule of 2026-11-01 ("don't force relays on users") no write goes here on top of the user's own
// relays (publishRelays); it is still read from (guest view, block-list lookups, mesh media).
export const BROADCAST_RELAYS = ["wss://relay.btcforplebs.com", "wss://relay.damus.io", "wss://relay.snort.social"]
const loopbackHost = h => { h = h.replace(/^\[|\]$/g, "").toLowerCase(); return h === "localhost" || h === "::1" || /^127\./.test(h) }
/** A relay on the machine the browser runs on (the Mac's own vault relay, ws://localhost:3355). */
export const isLoopback = url => loopbackHost(hostOf(url))
/**
 * A plain ws:// relay the page can't open: on an https page the browser blocks it (mixed content, and the site's CSP
 * connect-src has no ws:), so every ask failed at once and was asked again, 4-29 console errors a screen from one
 * ws:// entry in someone's kind 10002 (Ted's web sweep 2026-11-01). A loopback relay is left to its callers, which
 * already keep it to a page open on that same machine (publishRelays, own-relays.js): the Mac's own vault lives there.
 */
export const blockedPlain = (url, pageProtocol) => pageProtocol === "https:" && /^ws:\/\//i.test(String(url).trim()) && !isLoopback(url)

/**
 * The relays a new note (and every other write the user signs: reactions, reposts, lists, profile) goes to: the
 * user's own write relays (their kind 10002), nothing forced on top (Logen 2026-11-01: don't force relays on users).
 * With no usable write relay at all (no 10002 yet, or only junk in it) it is the recommended set a new account
 * starts on (DEFAULT_RELAYS). Dead hosts are dropped as the iPhone app drops them. A loopback relay is only reachable
 * from a page open on that same machine, so it is kept only there and marked local. Features with relays of their
 * own (purplepag.es for profiles and lists, WoT, live chat, NIP-46, a poll's relays) add them where they publish.
 * -> { network: [url], local: [url] }
 */
export function publishRelays(writeRelays, pageHost = globalThis.location?.hostname ?? "") {
  const clean = list => uniq(list.map(u => String(u).trim().replace(/\/+$/, "")).filter(u => /^wss?:\/\//.test(u)).filter(u => !isDead(u)))
  const own = clean(writeRelays)
  const live = own.length ? own : clean(DEFAULT_RELAYS)
  return { network: live.filter(u => !isLoopback(u)), local: loopbackHost(pageHost) ? live.filter(isLoopback) : [] }
}
