// Reading DMs from a relay that wants NIP-42 AUTH before it answers a REQ (a Haven inbox does: only its owner may
// read the wraps addressed to them). The relay closes the REQ with "auth-required: …"; we AUTH as the user and ask
// once more. Every AUTH is signed through dms.js authFor for that relay, so only a bare kind 22242 for one of the
// relays being read is ever signed.
//
// This is done here, per relay, rather than with nostr-tools 2.25.2's `onauth` option, which has three traps:
// - the REQ it re-sends after AUTH isn't kept, so closing the subscription leaves that REQ open (every resync would
//   stack another live DM subscription);
// - a sign function that throws leaves the relay's AUTH promise never settling, so the read never ends and the
//   socket's later AUTHs all wait on it;
// - each subscription on the socket would ask the signer itself.
// So the AUTH is signed here first, and only a signed one is handed to the relay, once per connection and challenge
// (a reconnect is AUTHed again). A relay that then refuses it, or never answers, is dropped so the next look opens a
// fresh socket; the live subscription on that relay was getting nothing from it anyway.
// When the signer doesn't sign (the user declined), that relay isn't asked about again until forgetDeclinedAuth(),
// which the explicit Refresh / Try again call: coming back to the tab must not bring the prompt back.
import { makeAuthEvent } from "nostr-tools/nip42"
import { normalizeURL } from "nostr-tools/utils"

/** How a relay's REQ ends when its AUTH was refused or never answered. */
export const AUTH_FAILED = "auth was required and attempted, but failed"
export const NOT_SIGNED = "auth-required: not signed"
/** How long an AUTH may take: a bunker signs over its own relay. */
export const AUTH_WAIT = { nip46: 20_000, other: 8000 }

const norm = u => { try { return normalizeURL(u) } catch { return "" } }
const declined = new Set() // relays whose AUTH the signer didn't sign (or left unanswered)
export const forgetDeclinedAuth = () => declined.clear()
// relay -> { conn, who, p }: the one AUTH tried on its current connection, in flight or done, shared by every read on
// it. One per connection, whatever the challenge: nostr-tools keeps a connection's first AUTH, so a second one is
// never sent (a relay that hands out a new challenge with every "auth-required" would otherwise be asked, and the
// signer prompted, hundreds of times a second: Tron, #879). A reconnect is a new connection (nostr-tools makes a new
// connectionPromise, and resets its own AUTH state), so it gets its own AUTH.
const authed = new WeakMap()
const sleep = ms => new Promise(r => setTimeout(r, ms))
// A race that doesn't leave its timer running once the work is done.
function within(ms, work) {
  let t
  return Promise.race([work, new Promise((_, reject) => { t = setTimeout(() => reject(new Error("AUTH not answered")), ms) })]).finally(() => clearTimeout(t))
}

// The relay sends its challenge on connect; a CLOSED can beat it by a moment.
async function challengeOf(relay) {
  for (let i = 0; i < 20 && !relay.challenge; i++) await sleep(50)
  return relay.challenge
}

/** AUTH this connection once: -> { conn } (the connection it let in) when it's in, or null. A wrapper, because an
 *  async function's result would unwrap the connection's promise. `sign(url, template)` signs, or throws when
 *  the signer won't; `who` is the account signing. `drop(url, relay)` drops a connection that can't be used. */
async function authOnce(relay, url, sign, who, authWait, drop) {
  const challenge = await challengeOf(relay)
  const conn = relay.connectionPromise
  if (!challenge || !conn) return null
  const cached = authed.get(relay)
  if (cached?.conn === conn) {
    if (cached.who === who) return cached.p
    // AUTHed as another account: this connection can't AUTH again, so it goes, and the next look starts afresh.
    try { drop(url, relay) } catch {}
    return null
  }
  const p = (async () => {
    let signed
    // A prompt left open, or a bunker that never answers, counts as declined: quiet until Refresh / Try again.
    try { signed = await within(authWait, sign(url, makeAuthEvent(relay.url, challenge))) }
    catch { declined.add(url); authed.delete(relay); return null } // nothing went to the relay: the connection can still AUTH later
    try { await within(authWait, relay.auth(async () => signed)); return { conn } }
    catch { try { drop(url, relay) } catch {} ; return null } // refused or unanswered: that socket keeps the failure
  })()
  authed.set(relay, { conn, who, p })
  return p
}

/**
 * Subscribe across `urls`, answering "auth-required" once per relay. `oneose` once every relay has sent EOSE or
 * closed; `onclose([{ url, reason }])` once every relay has closed. -> { close() }, which closes every REQ, the
 * re-sent ones included.
 */
export function authedSubscribe(net, urls, filter, { onevent, oneose, onclose, maxWait = 8000, sign, who = "", authWait = AUTH_WAIT.other, drop = dropConnection(net) } = {}) {
  const list = [...new Set(urls.map(norm).filter(Boolean))]
  // `answered`: the connection this relay's REQ was AUTHed on. Refused again on it means no further AUTH can help.
  const relays = new Map(list.map(url => [url, { sub: null, eosed: false, done: false, reason: "", answered: null }]))
  const seen = new Set()
  let closed = false, eoseSent = false, closeSent = false
  const check = () => {
    const all = [...relays.values()]
    if (!eoseSent && all.every(r => r.eosed || r.done)) { eoseSent = true; oneose?.() }
    if (!closeSent && all.every(r => r.done)) { closeSent = true; onclose?.(list.map(url => ({ url, reason: relays.get(url).reason }))) }
  }
  const end = (r, reason) => { if (r.done) return; r.done = true; r.reason = reason; check() }
  const open = (url, relay, r) => {
    if (closed) return
    r.eosed = false
    const sub = relay.subscribe([filter], {
      eoseTimeout: maxWait,
      alreadyHaveEvent: id => { if (seen.has(id)) return true; seen.add(id); return false },
      onevent: ev => onevent?.(ev),
      // A REQ the relay closed keeps its EOSE timer in nostr-tools: only the current REQ counts.
      oneose: () => { if (r.sub === sub) { r.eosed = true; check() } },
      onclose: reason => {
        if (r.sub !== sub) return
        r.sub = null
        const why = String(reason ?? "")
        if (closed || !why.startsWith("auth-required")) return end(r, why)
        if (declined.has(url)) return end(r, NOT_SIGNED)
        if (r.answered && r.answered === relay.connectionPromise) return end(r, AUTH_FAILED) // already AUTHed on this connection
        authOnce(relay, url, sign, who, authWait, drop).then(ok => {
          if (!ok) return end(r, declined.has(url) ? NOT_SIGNED : AUTH_FAILED)
          if (ok.conn === r.answered) return end(r, AUTH_FAILED)
          r.answered = ok.conn
          open(url, relay, r)
        })
      },
    })
    r.sub = sub
  }
  if (!list.length) queueMicrotask(check)
  for (const url of list) {
    const r = relays.get(url)
    const connect = () => net.ensureRelay(url, { connectionTimeout: maxWait })
    connect().then(async relay => {
      // A connection AUTHed as another account would carry this one's REQs under that identity: start a new one.
      const cached = authed.get(relay)
      if (cached && cached.who !== who && cached.conn === relay.connectionPromise) {
        authed.delete(relay)
        try { drop(url, relay) } catch {}
        relay = await connect()
      }
      // Another read may have just dropped it (as above): use the pool's current connection.
      if (net.relays && net.relays.get(url) !== relay) relay = await connect()
      open(url, relay, r)
    }).catch(err => end(r, `connection failure: ${err?.message ?? err}`))
  }
  return {
    close() {
      closed = true
      for (const r of relays.values()) { const s = r.sub; r.sub = null; try { s?.close() } catch {} }
    },
  }
}

/** Close the relay's connection, but only if it is still the one that failed (a newer one may have replaced it). */
const dropConnection = net => (url, relay) => { if (!net.relays || net.relays.get(norm(url)) === relay) net.close([url]) }

/** A query that answers AUTH and always ends: the events in by EOSE everywhere, or by the time an AUTH and a full
 *  wait could take. -> events */
export function queryWithAuth(net, urls, filter, { maxWait = 8000, authWait = AUTH_WAIT.other, sign, who, drop = dropConnection(net) } = {}) {
  return new Promise(resolve => {
    const events = []
    let done = false, sub = null
    const finish = () => { if (done) return; done = true; clearTimeout(timer); sub?.close(); resolve(events) }
    const timer = setTimeout(finish, maxWait + 2 * authWait + 2000) // a sign and an AUTH answer, each up to authWait
    sub = authedSubscribe(net, urls, filter, { maxWait, authWait, sign, who, drop, onevent: ev => events.push(ev), oneose: finish, onclose: finish })
  })
}
