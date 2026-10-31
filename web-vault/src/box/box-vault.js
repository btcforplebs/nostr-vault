// The vault in box mode: the same shape startVault returns (haven/vault.js), with the in-page haven.wasm replaced by
// sockets to the box's own relay. `haven.conn(name, { route })` gives each Haven route a websocket that speaks the
// NDJSON a HavenClient expects, so every caller of routeClient (dms.js, backup.js, the Vault dashboard) works as is.
// NIP-42: routeClient answers AUTH with this browser's device key, which the box doesn't know. The box trusts its
// owner (NV_OWNER), so each AUTH is signed again by the signed-in user's signer for this socket's URL, and the box's
// OK is handed back under the id the HavenClient is waiting on.
import { boxRelayUrl } from "./mode.js"

const enc = new TextEncoder(), dec = new TextDecoder()

/**
 * One route's socket as a havenConn: { write(Uint8Array), onData(cb), onClose(cb), close() }.
 * `signer`: the user's ({ signEvent }); `Socket`: WebSocket (injectable for tests).
 */
export function boxConn(route, { signer, Socket = globalThis.WebSocket, loc = globalThis.location } = {}) {
  const url = boxRelayUrl(route, loc)
  const ws = new Socket(url)
  let onData = () => {}, closed = false, buf = ""
  const closers = []
  const renamed = new Map() // id the box answers -> id the HavenClient waits on
  const opened = new Promise((resolve, reject) => {
    ws.onopen = () => resolve()
    ws.onerror = () => reject(new Error(`box relay unreachable: ${url}`))
  })
  let queue = Promise.resolve()
  const finish = () => { if (closed) return; closed = true; for (const cb of closers) cb() }
  ws.onclose = finish
  ws.onmessage = e => {
    let text = typeof e.data === "string" ? e.data : ""
    try {
      const msg = JSON.parse(text)
      if (msg[0] === "OK" && renamed.has(msg[1])) { const id = renamed.get(msg[1]); renamed.delete(msg[1]); text = JSON.stringify(["OK", id, ...msg.slice(2)]) }
    } catch {}
    onData(enc.encode(`${text}\n`))
  }
  const send = async line => {
    let out = line
    const msg = JSON.parse(line)
    if (msg[0] === "AUTH" && msg[1]?.kind === 22242) {
      const challenge = msg[1].tags.find(t => t[0] === "challenge")?.[1]
      const signed = await signer.signEvent({ kind: 22242, created_at: Math.floor(Date.now() / 1000), content: "", tags: [["relay", url], ["challenge", challenge]] })
      renamed.set(signed.id, msg[1].id)
      out = JSON.stringify(["AUTH", signed])
    }
    await opened
    ws.send(out)
  }
  return {
    url,
    write(bytes) {
      buf += dec.decode(bytes, { stream: true })
      const lines = buf.split("\n"); buf = lines.pop()
      for (const line of lines.filter(l => l.trim())) queue = queue.then(() => send(line)).catch(() => { ws.close(); finish() })
    },
    onData: cb => { onData = cb },
    onClose: cb => { closers.push(cb) },
    close: () => { ws.close(); finish() },
  }
}

/** The box's relay as a `haven`: conn() per route, stop() closes every socket. */
export function boxHaven({ signer, Socket, loc } = {}) {
  const open = new Set()
  return {
    box: true,
    conn(_name, { route = "/" } = {}) {
      const c = boxConn(route, { signer, Socket, loc })
      open.add(c)
      c.onClose(() => open.delete(c))
      return c
    },
    async stop() { for (const c of [...open]) c.close() },
  }
}

/** startVault for box mode -> { haven, owners: null, outbox, feed, inbox, loadMs, startMs }. `routeClient` from
 *  haven/vault.js, passed in so this file doesn't load haven.wasm's loader. */
export function startBoxVault({ signer, routeClient, deviceKey, Socket, loc }) {
  const t0 = Date.now()
  const haven = boxHaven({ signer, Socket, loc })
  const sk = deviceKey()
  const open = route => routeClient(haven, route, sk)
  return { haven, owners: null, box: true, outbox: open("/"), feed: open("/feed"), inbox: open("/inbox"), loadMs: 0, startMs: Date.now() - t0 }
}
