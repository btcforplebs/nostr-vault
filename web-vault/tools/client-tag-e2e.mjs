// The client tag, end to end: a kind 1 signed by the web app's own code (publishNote) with a throwaway key, sent to a
// real local relay, read back from that relay. With the desktop window's user agent (ua-probe.py prints it) it must
// carry ["client","Nostr Vault on Linux"]; with a plain browser's, ["client","Nostr Vault on Web"].
//   node web-vault/tools/client-tag-e2e.mjs <ws relay url> <throwaway sk hex> <window user agent>
// Never a real account's key: keytool gen makes the key, and the relay is a test vault owned by it.
import { finalizeEvent, getPublicKey, verifyEvent } from "nostr-tools/pure"
import { hexToBytes } from "nostr-tools/utils"

const [relay, skHex, windowUa] = process.argv.slice(2)
if (!relay || !/^[0-9a-f]{64}$/.test(skHex ?? "") || !windowUa) { console.error("usage: client-tag-e2e.mjs <relay> <skhex> <ua>"); process.exit(2) }
const sk = hexToBytes(skHex)
const pubkey = getPublicKey(sk)
const FIREFOX = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
const setUa = ua => Object.defineProperty(globalThis, "navigator", { value: { userAgent: ua }, configurable: true, writable: true })

setUa(windowUa)
const { publishNote } = await import("../src/net/sync.js")
let fail = 0, pass = 0
const check = (cond, what) => { console.log(`${cond ? "PASS" : "FAIL"}: ${what}`); if (cond) pass++; else fail++ }

const signer = { signEvent: async t => finalizeEvent(t, sk) }
const vault = { outbox: { event: async () => ({ ok: true, message: "" }) } } // the page's own Haven: not this test's
const posted = []
for (const [ua, want, who] of [[windowUa, "Nostr Vault on Linux", "the desktop window"], [FIREFOX, "Nostr Vault on Web", "a plain browser"]]) {
  setUa(ua)
  const r = await publishNote(vault, signer, pubkey, `client tag e2e from ${who} ${Date.now()}`, [relay])
  check(r.relays.length === 1 && r.relays[0].ok, `the relay took the note from ${who} (${r.relays[0]?.ok ? "ok" : r.relays[0]?.message || "no answer"})`)
  posted.push({ id: r.event.id, want, who })
}

// Read them back from the relay, not from what we signed.
const got = await new Promise((resolve, reject) => {
  const ws = new WebSocket(relay), evs = []
  const timer = setTimeout(() => { ws.close(); reject(new Error("no EOSE in 20 s")) }, 20000)
  ws.onopen = () => ws.send(JSON.stringify(["REQ", "e2e", { ids: posted.map(p => p.id) }]))
  ws.onmessage = m => {
    const msg = JSON.parse(m.data)
    if (msg[0] === "EVENT") evs.push(msg[2])
    if (msg[0] === "EOSE" || msg[0] === "CLOSED") { clearTimeout(timer); ws.close(); resolve(evs) }
  }
  ws.onerror = e => { clearTimeout(timer); reject(new Error(`relay: ${e.message ?? "error"}`)) }
})
for (const p of posted) {
  const ev = got.find(e => e.id === p.id)
  check(!!ev && verifyEvent(ev) && ev.pubkey === pubkey && ev.kind === 1, `the relay returns the signed kind 1 from ${p.who}`)
  const tags = (ev?.tags ?? []).filter(t => t[0] === "client")
  check(JSON.stringify(tags) === JSON.stringify([["client", p.want]]), `from ${p.who}: ${JSON.stringify(tags)} is [["client","${p.want}"]]`)
}
console.log(`RESULT client-tag pass=${pass} fail=${fail}`)
process.exit(fail ? 1 : 0)
