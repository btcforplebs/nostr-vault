// Notes backup, in the iPhone's format: a .zip with one "<database>.jsonl" per Haven database, one event per line
// (haven-go/jsonl.go exportToZip, what Settings › Backup › Export Notes saves). A web backup restores on the iPhone and
// an iPhone backup restores here. Media (Blossom files) is not in it, on the iPhone either: that is its own backup.
//
// The web reads its stores through Haven's NIP-01 routes, so its policies apply both ways. Reading: these routes refuse
// a filter with no kind, author, id or tag, so each database is read with filters that cover what its route accepts.
// Restoring: only events the export's filters would read back go in (so a crafted backup can't put someone else's notes
// in your outbox), and each is sent to its route like any client's, so Haven checks the signature and the route's
// policy; whatever it refuses is counted, never written behind its back. Nothing is published: the web Haven has no
// blastr relays (BLASTR_RELAYS_FILE is unset), the same as when sync.js stores your own notes in the outbox.
import { finalizeEvent, getPublicKey } from "nostr-tools/pure"
import { matchFilters } from "nostr-tools/filter"
import { makeAuthEvent } from "nostr-tools/nip42"
import { HavenClient } from "../../../web-relay/src/haven/client.js"
import { deviceKey } from "../haven/vault.js"

const RELAY_HOST = "vault.local" // vault.js: Haven's ServiceURL, which NIP-42 AUTH is checked against
// haven-go feedKinds (feedsync.go), plus kind 0, which the page's own stream caches there.
const FEED_KINDS = [0, 1, 6, 16, 20, 1068, 1111, 9802, 30023]
// haven-go allowedChatKinds (policies.go), plus 5: the owner's delete requests are kept there too.
const CHAT_KINDS = [5, 9, 10, 11, 12, 42, 43, 1059, 9000, 9001, 9002, 9005, 9007, 9008, 9009, 9021, 9022, 39000, 39001, 39002, 39003]

/** Database (file name in the zip) -> its route and the filters that read all of it. `me` is the account, `dev` the
 *  device key Haven whitelists (the only other key a whitelisted write can come from). */
export const DATABASES = {
  outbox: { route: "/", filters: (me, dev) => [{ authors: [me, dev] }] },
  private: { route: "/private", filters: () => [{}] },
  chat: { route: "/chat", filters: () => [{ kinds: CHAT_KINDS }] },
  inbox: { route: "/inbox", filters: (me, dev) => [{ "#p": [me, dev] }, { kinds: [5], authors: [me] }] },
  feed: { route: "/feed", filters: () => [{ kinds: FEED_KINDS }] },
}

const PAGE = 500

// A second with more events than a page can't be paged by created_at: it is read on its own, up to this many.
const ONE_SECOND = 5000

/** Every event a filter matches, newest first, paging back by created_at (until is inclusive, so pages overlap by a
 *  second and are deduped). */
export async function readAll(client, filter, page = PAGE) {
  const seen = new Map()
  const add = evs => { let fresh = 0; for (const ev of evs) if (!seen.has(ev.id)) { seen.set(ev.id, ev); fresh++ } return fresh }
  let until
  for (;;) {
    const evs = await client.query({ ...filter, limit: page, ...(until !== undefined ? { until } : {}) })
    if (!evs.length) break
    const oldest = Math.min(...evs.map(e => e.created_at))
    if (add(evs)) { until = oldest; continue }
    // Nothing new: the whole page is one second. Read that second by itself, then step past it.
    add(await client.query({ ...filter, since: oldest, until: oldest, limit: ONE_SECOND }))
    until = oldest - 1
    if (until < 0) break
  }
  return [...seen.values()].sort((a, b) => b.created_at - a.created_at)
}

/** One owner stream per database, AUTHed with the device key like vault.js's own. */
function openRoute(vault, name, sk) {
  const { route } = DATABASES[name]
  const conn = vault.haven.conn(`backup-${name}-${Date.now()}`, { mode: "nip01", route, owner: true })
  return new HavenClient(conn, { auth: challenge => finalizeEvent(makeAuthEvent(`wss://${RELAY_HOST}${route}`, challenge), sk) })
}

/** -> { blob: the .zip, counts: { database: events } }. `onProgress(name)` as each database starts. */
export async function exportNotes({ vault, pubkey, sk = deviceKey(), onProgress = () => {}, open = openRoute }) {
  const files = []
  const counts = {}
  const dev = getPublicKey(sk)
  for (const [name, db] of Object.entries(DATABASES)) {
    onProgress(name)
    const client = open(vault, name, sk)
    try {
      const byId = new Map()
      for (const f of db.filters(pubkey, dev)) for (const ev of await readAll(client, f)) byId.set(ev.id, ev)
      const evs = [...byId.values()].sort((a, b) => b.created_at - a.created_at)
      counts[name] = evs.length
      files.push({ name: `${name}.jsonl`, data: new TextEncoder().encode(evs.map(e => JSON.stringify(e) + "\n").join("")) })
    } finally {
      client.close?.()
    }
  }
  return { blob: new Blob([await zip(files)], { type: "application/zip" }), counts }
}

/**
 * Restore a backup .zip (from here or the iPhone) into this account's stores.
 * -> { counts: { database: { stored, refused, bad, why? } }, skipped: file names this vault has no database for }
 * "refused" is Haven saying no (bad signature, someone else's account, a kind the route doesn't take), and a duplicate
 * of an event already here is "stored": it is there.
 */
export async function importNotes({ vault, pubkey, bytes, sk = deviceKey(), onProgress = () => {}, open = openRoute }) {
  const counts = {}
  const dev = getPublicKey(sk)
  const skipped = []
  for (const entry of await unzip(bytes)) {
    const name = entry.name.replace(/\.jsonl$/, "")
    if (!entry.name.endsWith(".jsonl") || !DATABASES[name]) { skipped.push(entry.name); continue }
    onProgress(name)
    const c = (counts[name] = { stored: 0, refused: 0, bad: 0 })
    const belongs = DATABASES[name].filters(pubkey, dev)
    const client = open(vault, name, sk)
    try {
      // Most routes only take writes from an AUTHed whitelisted key. One read first AUTHs on the routes whose reads
      // need it; the rest (/inbox) are AUTHed by storeEvent on their first refusal.
      await client.query({ ids: ["0".repeat(64)] }).catch(() => {})
      const store = storeEvent(client)
      for (const line of new TextDecoder().decode(await entry.read()).split("\n")) {
        if (!line.trim()) continue
        let ev
        try { ev = JSON.parse(line) } catch { c.bad++; continue }
        if (!ev || typeof ev.id !== "string" || typeof ev.sig !== "string" || !Array.isArray(ev.tags)) { c.bad++; continue }
        if (!matchFilters(belongs, ev)) { c.refused++; continue }
        const r = await store(ev)
        if (r.ok || /^duplicate:/.test(r.message ?? "")) c.stored++
        else { c.refused++; c.why ??= r.message } // the first reason, so the screen can say what Haven objected to
      }
    } finally {
      client.close?.()
    }
  }
  return { counts, skipped }
}

/**
 * client.event(ev), AUTHing once when Haven answers "auth-required". HavenClient only answers AUTH for reads, and a
 * route like /inbox never asks on a read: Haven sends its challenge with the refusal. Haven handles a stream's messages
 * concurrently, so the AUTH can land after the retry; the retry backs off a few times before giving up.
 */
export function storeEvent(client, delays = [0, 20, 100, 400]) {
  let authSent = false
  const send = ev => client.event(ev).catch(e => ({ ok: false, message: String(e?.message ?? e) }))
  return async ev => {
    let r = await send(ev)
    for (const ms of delays) {
      if (r.ok || !/^auth-required:/.test(r.message ?? "") || !client.challenge || !client.auth) return r
      if (!authSent) {
        authSent = true
        const auth = await client.auth(client.challenge)
        client.conn.write(new TextEncoder().encode(JSON.stringify(["AUTH", auth]) + "\n"))
      }
      await new Promise(res => setTimeout(res, ms))
      r = await send(ev)
    }
    return r
  }
}

// ---- zip: just enough for these files. Deflate when the browser has CompressionStream, else stored. ----

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0 })
export function crc32(bytes) {
  let c = 0xffffffff
  for (const b of bytes) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

const pipe = async (bytes, stream) => new Uint8Array(await new Response(new Blob([bytes]).stream().pipeThrough(stream)).arrayBuffer())

/** [{ name, data: Uint8Array }] -> zip bytes */
export async function zip(files, { now = new Date(), deflate = typeof CompressionStream === "function" } = {}) {
  const enc = new TextEncoder()
  const dosTime = (now.getHours() << 11) | (now.getMinutes() << 5) | (now.getSeconds() >> 1)
  const dosDate = ((now.getFullYear() - 1980) << 9) | ((now.getMonth() + 1) << 5) | now.getDate()
  const parts = []
  const central = []
  let offset = 0
  for (const f of files) {
    const name = enc.encode(f.name)
    const body = deflate ? await pipe(f.data, new CompressionStream("deflate-raw")) : f.data
    const crc = crc32(f.data)
    const head = (sig, extra) => {
      const h = new DataView(new ArrayBuffer(extra ? 46 : 30))
      let i = 0
      const u32 = v => { h.setUint32(i, v, true); i += 4 }
      const u16 = v => { h.setUint16(i, v, true); i += 2 }
      u32(sig)
      if (extra) u16(20) // version made by
      u16(20); u16(0x0800); u16(deflate ? 8 : 0); u16(dosTime); u16(dosDate) // version, flags (UTF-8 name), method
      u32(crc); u32(body.length); u32(f.data.length); u16(name.length); u16(0)
      if (extra) { u16(0); u16(0); u16(0); u32(0); u32(offset) } // comment, disk, attrs, local header offset
      return new Uint8Array(h.buffer)
    }
    const local = head(0x04034b50, false)
    central.push(head(0x02014b50, true), name)
    parts.push(local, name, body)
    offset += local.length + name.length + body.length
  }
  const cdSize = central.reduce((n, p) => n + p.length, 0)
  const end = new DataView(new ArrayBuffer(22))
  end.setUint32(0, 0x06054b50, true)
  end.setUint16(8, files.length, true); end.setUint16(10, files.length, true)
  end.setUint32(12, cdSize, true); end.setUint32(16, offset, true)
  return new Uint8Array(await new Blob([...parts, ...central, new Uint8Array(end.buffer)]).arrayBuffer())
}

/** zip bytes -> [{ name, read(): Promise<Uint8Array> }], from the central directory. Stored and deflated entries. */
export async function unzip(bytes) {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)
  const v = new DataView(b.buffer, b.byteOffset, b.byteLength)
  let end = -1
  for (let i = b.length - 22; i >= Math.max(0, b.length - 22 - 65535); i--) if (v.getUint32(i, true) === 0x06054b50) { end = i; break }
  if (end < 0) throw new Error("That file isn't a backup .zip.")
  const total = v.getUint16(end + 10, true)
  let p = v.getUint32(end + 16, true)
  if (total === 0xffff || p === 0xffffffff) throw new Error("This backup is too large to open here (zip64).")
  const dec = new TextDecoder()
  const out = []
  for (let n = 0; n < total; n++) {
    if (v.getUint32(p, true) !== 0x02014b50) throw new Error("This backup .zip is damaged.")
    const method = v.getUint16(p + 10, true)
    const crc = v.getUint32(p + 16, true)
    const size = v.getUint32(p + 20, true)
    const nameLen = v.getUint16(p + 28, true), extraLen = v.getUint16(p + 30, true), commentLen = v.getUint16(p + 32, true)
    const at = v.getUint32(p + 42, true)
    const name = dec.decode(b.subarray(p + 46, p + 46 + nameLen))
    p += 46 + nameLen + extraLen + commentLen
    const read = async () => {
      const start = at + 30 + v.getUint16(at + 26, true) + v.getUint16(at + 28, true)
      const raw = b.subarray(start, start + size)
      let data
      if (method === 0) data = raw
      else if (method === 8) data = await pipe(raw, new DecompressionStream("deflate-raw"))
      else throw new Error(`${name} is compressed in a way this browser can't open.`)
      if (crc32(data) !== crc) throw new Error(`${name} in this backup is damaged.`)
      return data
    }
    out.push({ name, read })
  }
  return out
}
