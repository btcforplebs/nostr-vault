// The vault in box mode: the same shape startVault returns (haven/vault.js), with the in-page haven.wasm replaced by
// sockets to the box's own relay. `haven.conn(name, { route })` gives each Haven route a websocket that speaks the
// NDJSON a HavenClient expects, so every caller of routeClient (dms.js, backup.js, the Vault dashboard) works as is.
// NIP-42: routeClient answers AUTH with this browser's device key, which the box doesn't know. The box trusts its
// owner (NV_OWNER), so each AUTH is signed again by the signed-in user's signer for this socket's URL, and the box's
// OK is handed back under the id the HavenClient is waiting on.
import { boxRelayUrl } from "./mode.js"
import { checkSigned } from "../net/sync.js"
import { loadSession } from "../session.js"

const enc = new TextEncoder(), dec = new TextDecoder()

// Logins (signer audit 2026-11-05 #4): a box socket that has logged in (the box answered its AUTH OK) is kept when its client closes and handed to
// the next client of that route, so a Vault Dashboard, a backup or a re-opened stream doesn't ask the signer again.
// A login the user declines is remembered for the page (until retryLogin, or a reload), so polled reads don't
// re-prompt every few minutes. A signer that never answered (a bunker timeout, `unreachable`) didn't decline: the next
// read asks again (Tron 1745). A signed AUTH that isn't the signed-in account's is never sent.
export const LOGIN_DECLINED = "You declined to log in to your box, so it wasn't asked again. Reload the page to log in."
const IDLE_PER_ROUTE = 4
// Subscription ids (Tron 1745): each HavenClient numbers its own q1, q2..., so a kept socket could hand a new client
// the box's answers to the old client's still-open q1. Every client of a link gets its own prefix on the way out, it is
// taken off on the way back, and an answer with another client's prefix is dropped. Its open REQs are CLOSEd on give.
const SUB_OUT = new Set(["REQ", "COUNT", "CLOSE"]), SUB_IN = new Set(["EVENT", "EOSE", "CLOSED", "COUNT"])

/** The box's sockets for one page: `link(route)` hands out an idle logged-in socket of that route, or a new one. */
function boxLinks({ signer, pubkey, Socket = globalThis.WebSocket, loc = globalThis.location } = {}) {
  const idle = new Map() // route -> [link]
  const login = { declined: false }
  const me = () => (typeof pubkey === "function" ? pubkey() : pubkey) ?? loadSession()?.pubkey ?? null

  const sign = async (url, challenge) => {
    if (login.declined) throw new Error(LOGIN_DECLINED)
    const template = { kind: 22242, created_at: Math.floor(Date.now() / 1000), content: "", tags: [["relay", url], ["challenge", challenge]] }
    let signed
    try { signed = await signer.signEvent(template) } catch (e) { if (!e?.unreachable) login.declined = true; throw e }
    const who = me()
    // checkSigned: the event asked for, validly signed, by the signed-in account (not whatever the signer is on).
    return who ? checkSigned(signed, template, who) : signed
  }

  const open = route => {
    const url = boxRelayUrl(route, loc)
    const ws = new Socket(url)
    const link = { url, route, ws, user: null, alive: true, renamed: new Map(), gen: 0, tag: "", subs: new Set() } // renamed: id the box answers -> id the client waits on
    link.opened = new Promise((resolve, reject) => {
      ws.onopen = () => resolve()
      ws.onerror = () => reject(new Error(`box relay unreachable: ${url}`))
    })
    link.opened.catch(() => {})
    ws.onclose = () => {
      link.alive = false
      const list = idle.get(route)
      if (list) idle.set(route, list.filter(l => l !== link))
      link.user?.closed()
    }
    ws.onmessage = e => {
      let text = typeof e.data === "string" ? e.data : ""
      try {
        const msg = JSON.parse(text)
        if (msg[0] === "OK" && link.renamed.has(msg[1])) {
          const id = link.renamed.get(msg[1]); link.renamed.delete(msg[1]); text = JSON.stringify(["OK", id, ...msg.slice(2)])
          // The box took the login: this socket is worth keeping. It refused it (this account isn't the box's owner):
          // asking the signer again won't change that, so it isn't asked again either.
          if (msg[2] === true) link.loggedIn = true
          else login.declined = true
        } else if (SUB_IN.has(msg[0]) && typeof msg[1] === "string") {
          if (!link.tag || !msg[1].startsWith(link.tag)) return // another (closed) client's subscription
          const id = msg[1].slice(link.tag.length)
          if (msg[0] === "CLOSED" || msg[0] === "COUNT") link.subs.delete(msg[1])
          text = JSON.stringify([msg[0], id, ...msg.slice(2)])
        }
      } catch {}
      link.user?.data(enc.encode(`${text}\n`))
    }
    return link
  }

  return {
    login,
    take(route) {
      const list = idle.get(route) ?? []
      let link
      while ((link = list.pop()) && !link.alive) {}
      link ??= open(route)
      link.tag = `c${++link.gen}:`
      return link
    },
    // A client is done with `link`: an open socket waits for the route's next client, else it is closed.
    give(link) {
      link.user = null
      if (link.alive && link.loggedIn) for (const sub of link.subs) link.ws.send(JSON.stringify(["CLOSE", sub]))
      link.subs.clear()
      link.tag = "" // answers still on their way for this client are dropped
      const list = idle.get(link.route) ?? []
      if (!link.alive || !link.loggedIn || list.length >= IDLE_PER_ROUTE) { link.alive = false; link.ws.close(); return }
      idle.set(link.route, [...list, link])
    },
    sign,
    closeAll() { for (const list of idle.values()) for (const l of list) { l.alive = false; l.ws.close() } idle.clear() },
  }
}

/**
 * One route's socket as a havenConn: { write(Uint8Array), onData(cb), onClose(cb), close() }.
 * `signer`: the user's ({ signEvent }); `Socket`: WebSocket (injectable for tests); `links`: the page's boxLinks
 * (one is made when not given); `pubkey`: the signed-in account (the session's when not given).
 */
export function boxConn(route, { signer, Socket = globalThis.WebSocket, loc = globalThis.location, links, pubkey } = {}) {
  const pool = links ?? boxLinks({ signer, Socket, loc, pubkey })
  const link = pool.take(route)
  const { url, ws } = link
  let onData = () => {}, done = false, buf = ""
  const closers = []
  let queue = Promise.resolve()
  const finish = () => { if (done) return; done = true; for (const cb of closers) cb() }
  link.user = { data: b => onData(b), closed: finish }
  const tag = link.tag
  const send = async line => {
    const msg = JSON.parse(line)
    if (done && msg[0] !== "CLOSE") return // queued before close: the socket may be another client's now
    if (SUB_OUT.has(msg[0]) && typeof msg[1] === "string") {
      msg[1] = tag + msg[1]
      if (msg[0] === "CLOSE") link.subs.delete(msg[1]); else link.subs.add(msg[1])
    }
    let out = JSON.stringify(msg)
    if (msg[0] === "AUTH" && msg[1]?.kind === 22242) {
      const challenge = msg[1].tags.find(t => t[0] === "challenge")?.[1]
      const signed = await pool.sign(url, challenge)
      link.renamed.set(signed.id, msg[1].id)
      out = JSON.stringify(["AUTH", signed])
    }
    await link.opened
    if (done && msg[0] !== "CLOSE") { link.subs.delete(msg[1]); return }
    ws.send(out)
  }
  return {
    url,
    write(bytes) {
      buf += dec.decode(bytes, { stream: true })
      const lines = buf.split("\n"); buf = lines.pop()
      for (const line of lines.filter(l => l.trim())) queue = queue.then(() => send(line)).catch(() => { link.alive = false; ws.close(); finish() })
    },
    onData: cb => { onData = cb },
    onClose: cb => { closers.push(cb) },
    // The client is done: its socket goes back to the page for the next client of this route (logged in already).
    close: () => { if (done) return; done = true; pool.give(link); for (const cb of closers) cb() },
  }
}

/** The box's relay as a `haven`: conn() per route, stop() closes every socket. retryLogin() asks the signer again
 *  after a declined login. */
export function boxHaven({ signer, Socket, loc, pubkey } = {}) {
  const links = boxLinks({ signer, Socket, loc, pubkey })
  const open = new Set()
  return {
    box: true,
    conn(_name, { route = "/" } = {}) {
      const c = boxConn(route, { signer, Socket, loc, links })
      open.add(c)
      c.onClose(() => open.delete(c))
      return c
    },
    retryLogin() { links.login.declined = false },
    async stop() { for (const c of [...open]) c.close(); links.closeAll() },
  }
}

/** startVault for box mode -> { haven, owners: null, outbox, feed, inbox, lists, loadMs, startMs }. `routeClient` from
 *  haven/vault.js, passed in so this file doesn't load haven.wasm's loader. */
export function startBoxVault({ signer, routeClient, deviceKey, Socket, loc }) {
  const t0 = Date.now()
  const haven = boxHaven({ signer, Socket, loc })
  const sk = deviceKey()
  const open = route => routeClient(haven, route, sk)
  return { haven, owners: null, box: true, outbox: open("/"), feed: open("/feed"), inbox: open("/inbox"), lists: open("/lists"), loadMs: 0, startMs: Date.now() - t0 }
}
