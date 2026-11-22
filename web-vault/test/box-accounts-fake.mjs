// A pretend box for the Accounts tests (box-accounts*.test.mjs): answers routes_accounts.go's shapes from memory, and
// checks each request's NIP-98 header (signature, URL, method, payload hash) the way the box does, so the caller is
// whoever really signed. Plus just enough DOM for preact. Made-up keys; nothing is sent anywhere.
import { verifyEvent } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { sha256 } from "@noble/hashes/sha2.js"
import { bytesToHex } from "@noble/hashes/utils.js"

class Node {
  constructor(nodeType, localName) { this.nodeType = nodeType; this.localName = localName; this.childNodes = []; this.parentNode = null; this.style = {}; this.attributes = {} }
  get firstChild() { return this.childNodes[0] ?? null }
  get nextSibling() { const s = this.parentNode?.childNodes; return s ? s[s.indexOf(this) + 1] ?? null : null }
  insertBefore(n, ref) {
    n.parentNode?.removeChild(n)
    const i = ref ? this.childNodes.indexOf(ref) : -1
    i < 0 ? this.childNodes.push(n) : this.childNodes.splice(i, 0, n)
    n.parentNode = this
    return n
  }
  appendChild(n) { return this.insertBefore(n, null) }
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n }
  remove() { this.parentNode?.removeChild(this) }
  setAttribute(k, v) { this.attributes[k] = String(v) }
  removeAttribute(k) { delete this.attributes[k] }
  addEventListener(type, fn) { (this.on ??= {})[type] = fn }
  removeEventListener() {}
  get textContent() { return this.nodeType === 3 ? this.data : this.childNodes.map(c => c.textContent).join("") }
  set textContent(v) { this.childNodes = []; if (v) this.appendChild(document.createTextNode(v)) }
}
export function fakeDom() {
  globalThis.document = {
    createElement: name => new Node(1, name),
    createElementNS: (_, name) => new Node(1, name),
    createTextNode: data => Object.assign(new Node(3, "#text"), { data: String(data) }),
  }
}
export const tick = (ms = 0) => new Promise(r => setTimeout(r, ms))
export const all = (n, out = []) => { if (n.nodeType === 1) out.push(n); n.childNodes.forEach(c => all(c, out)); return out }
export const fire = (n, name, extra = {}) => {
  const type = Object.keys(n.on ?? {}).find(k => k.toLowerCase() === name)
  if (!type) throw new Error(`no ${name} listener on ${n.localName}`)
  return n.on[type].call(n, { type, currentTarget: n, target: n, preventDefault() {}, stopPropagation() {}, ...extra })
}
export const button = (el, label) => all(el).find(n => n.localName === "button" && n.textContent === label)

/** `owner`: the first account's hex key. `log`: every answered request, { method, name, who, status }. */
export function fakeAccountsBox({ owner, now = () => Date.now() }) {
  const added = new Map() // npub -> { state, added, name }
  const codes = new Set()
  const log = []
  const answer = (status, body) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
  const stateOf = hex => hex === owner ? "first" : added.get(npubEncode(hex))?.state ?? "none"
  const fetchImpl = async (url, { method = "GET", headers = {}, body } = {}) => {
    const name = new URL(url).pathname.replace(/^\/api\/box\//, "")
    const done = (who, status, b) => { log.push({ method, name, who, status, body: b }); return answer(status, b) }
    let ev
    try { ev = JSON.parse(atob(String(headers.Authorization ?? "").replace(/^Nostr /, ""))) } catch { return done(null, 401, { error: "no NIP-98 header" }) }
    const tag = k => ev.tags.find(t => t[0] === k)?.[1]
    if (ev.kind !== 27235 || !verifyEvent(ev) || tag("u") !== url || tag("method") !== method) return done(null, 401, { error: "bad NIP-98 event" })
    if (body && tag("payload") !== bytesToHex(sha256(new TextEncoder().encode(body)))) return done(null, 401, { error: "payload hash" })
    const who = ev.pubkey, state = stateOf(who), req = body ? JSON.parse(body) : {}
    const anyone = name === "accounts/me" || name === "accounts/join"
    if (state !== "first" && state !== "signedIn" && !anyone) return done(who, 403, { error: "only the owner may use the box API" })
    if (!anyone && state !== "first") return done(who, 403, { error: "only the box's first account may do this" })
    if (name === "accounts" && method === "GET") return done(who, 200, { accounts: [{ npub: npubEncode(owner), state: "first" }, ...[...added].map(([npub, a]) => ({ npub, ...a }))] })
    if (name === "accounts/me") return done(who, 200, { npub: npubEncode(who), state })
    if (name === "accounts/code") { const code = `ABCD${codes.size}EFGH${codes.size}JK`.slice(0, 12); codes.add(code); return done(who, 200, { code, expiresAt: Math.floor(now() / 1000) + 900 }) }
    if (name === "accounts/join") {
      if (state === "first") return done(who, 409, { error: "that is the box's first account: it can't be added, joined or removed" })
      if (state === "signedIn") return done(who, 200, { npub: npubEncode(who), state, already: true })
      const code = String(req.code ?? "").replace(/[-\s]/g, "").toUpperCase()
      if (!codes.delete(code)) return done(who, 403, { error: "that code isn't right or has expired: ask the box's owner for a new one" })
      const a = { state: "signedIn", added: Math.floor(now() / 1000), ...(req.name && { name: req.name }) }
      added.set(npubEncode(who), a)
      return done(who, 200, { npub: npubEncode(who), ...a })
    }
    if (name === "accounts/remove") {
      if (req.npub === npubEncode(owner)) return done(who, 409, { error: "that is the box's first account: it can't be added, joined or removed" })
      if (!added.delete(req.npub)) return done(who, 404, { error: "this box doesn't hold that account" })
      return done(who, 200, { removed: req.npub, kept: "notes and files" })
    }
    return done(who, 404, { error: "no such box API route" })
  }
  return { fetchImpl, log, added, codes, addWatchOnly: hex => added.set(npubEncode(hex), { state: "watchOnly", added: 1795300000 }) }
}
