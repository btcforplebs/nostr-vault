// Read a blob from a vault's mesh port 80 (the vault's relay, which also serves Blossom: GET /<sha256>) over the
// page's FIPS node. The request goes over the IPv6 shim (./ipv6-shim.js), in the same FIPS session the page holds
// to that vault through the seed, so the page never learns the vault's IP and the vault only learns the seed's.
// The body is only returned when its sha256 is the hash asked for.
import { FipsTcpEndpoint } from "@fips/tcp"
import { sha256 } from "@noble/hashes/sha2.js"
import { decode, npubEncode } from "nostr-tools/nip19"
import { ipv6ShimEndpoint } from "./ipv6-shim.js"
import { xOnly } from "./owners.js"

export const MESH_HTTP_PORT = 80
export const MAX_BLOB_BYTES = 64 * 1024 * 1024
const MAX_HEAD = 16 * 1024
// The only types a fetched blob keeps. Its Blob URL has the page's origin, so a vault-chosen image/svg+xml or
// text/html opened in a tab would run script there (and could read the page's FIPS key). Anything else is
// handed over as application/octet-stream: <img> and <video> still sniff it, a new tab only downloads it.
const SAFE_TYPES = /^(image\/(jpeg|png|gif|webp|avif|heic|heif)|video\/(mp4|webm|quicktime))$/
const POLL_MS = 20
const READ_CHUNK = 256 * 1024
// Connecting may take this long (route retries through the seed); after that it's the longest the vault may go quiet.
const DEFAULT_TIMEOUT_MS = 60_000
// Raw bytes allowed for one response: the blob, its head, and chunk framing down to ~512-byte chunks.
const MAX_RAW_BYTES = MAX_BLOB_BYTES + MAX_HEAD + MAX_BLOB_BYTES / 64
// After a finished read, keep polling this long so our FIN is retransmitted and the stack can forget the stream.
const LINGER_MS = 5_000
const RETRY_MS = 1_000
const SHA256 = /^[0-9a-f]{64}$/

const toHex = b => Array.from(b, x => x.toString(16).padStart(2, "0")).join("")
const abortError = () => Object.assign(new Error("read cancelled"), { name: "AbortError" })
const ascii = b => new TextDecoder().decode(b)

/**
 * What to fetch from a pasted reference: a bare sha256, `<sha256>.<ext>`, or a NIP-F1 link
 * `http://<vault-mesh-npub>.fips/<sha256>[.ext]` (the vault comes from the host). Throws on anything else.
 */
export function parseBlobRef(text) {
  const t = String(text ?? "").trim()
  const bare = t.toLowerCase().match(/^([0-9a-f]{64})(\.[a-z0-9]{1,8})?$/)
  if (bare) return { sha256: bare[1] }
  let url
  try {
    url = new URL(t)
  } catch {
    throw new Error("not a sha256 or a .fips link")
  }
  const host = url.hostname.toLowerCase().match(/^(npub1[02-9ac-hj-np-z]+)\.fips$/)
  const path = url.pathname.toLowerCase().match(/^\/([0-9a-f]{64})(\.[a-z0-9]{1,8})?$/)
  if (url.protocol !== "http:" || !host || !path) throw new Error("not a .fips blob link: http://<npub>.fips/<sha256>")
  if (decode(host[1]).type !== "npub") throw new Error("not a mesh address")
  return { sha256: path[1], vault: xOnly(host[1]) }
}

/** Split an HTTP/1.1 response once its head is complete: { status, headers, bodyStart } or undefined. */
export function parseHead(buf) {
  const n = indexOf(buf, [13, 10, 13, 10])
  if (n < 0) {
    if (buf.length > MAX_HEAD) throw new Error("response head too long")
    return undefined
  }
  const lines = ascii(buf.subarray(0, n)).split("\r\n")
  const m = lines[0].match(/^HTTP\/1\.[01] (\d{3})/)
  if (!m) throw new Error("not an HTTP response")
  const headers = new Map()
  for (const l of lines.slice(1)) {
    const i = l.indexOf(":")
    if (i > 0) headers.set(l.slice(0, i).trim().toLowerCase(), l.slice(i + 1).trim())
  }
  return { status: Number(m[1]), headers, bodyStart: n + 4 }
}

function indexOf(buf, pat, from = 0) {
  outer: for (let i = from; i <= buf.length - pat.length; i++) {
    for (let j = 0; j < pat.length; j++) if (buf[i + j] !== pat[j]) continue outer
    return i
  }
  return -1
}

/** Decode a complete chunked body, or undefined while it's still incomplete. */
export function dechunk(buf) {
  const parts = []
  let total = 0
  for (let at = 0; ; ) {
    const eol = indexOf(buf, [13, 10], at)
    if (eol < 0) return undefined
    const size = parseInt(ascii(buf.subarray(at, eol)).split(";")[0].trim(), 16)
    if (!Number.isFinite(size) || size < 0) throw new Error("bad chunk size")
    if (size === 0) return concat(parts, total)
    if ((total += size) > MAX_BLOB_BYTES) throw new Error("blob too large")
    const start = eol + 2
    if (buf.length < start + size + 2) return undefined
    parts.push(buf.subarray(start, start + size))
    at = start + size + 2
  }
}

function concat(parts, total) {
  const out = new Uint8Array(total)
  let o = 0
  for (const p of parts) { out.set(p, o); o += p.length }
  return out
}

/** The body, once the response is complete (`closed`: the vault finished sending), else undefined. */
function body(head, bytes, closed) {
  const rest = bytes.subarray(head.bodyStart)
  if (/\bchunked\b/i.test(head.headers.get("transfer-encoding") ?? "")) return dechunk(rest)
  const len = head.headers.get("content-length")
  if (len !== undefined) {
    const n = Number(len)
    if (!Number.isSafeInteger(n) || n < 0) throw new Error("bad content-length")
    if (n > MAX_BLOB_BYTES) throw new Error("blob too large")
    return rest.length >= n ? rest.subarray(0, n) : closed ? fail("connection closed early") : undefined
  }
  return closed ? rest : undefined
}

const fail = msg => { throw new Error(msg) }

/** An append-only byte buffer that doubles, so a large blob isn't copied once per read. */
class Grow {
  constructor() { this.buf = new Uint8Array(64 * 1024); this.length = 0 }
  push(b) {
    if (this.length + b.length > this.buf.length) {
      const next = new Uint8Array(Math.max(this.buf.length * 2, this.length + b.length))
      next.set(this.buf.subarray(0, this.length))
      this.buf = next
    }
    this.buf.set(b, this.length)
    this.length += b.length
  }
  bytes() { return this.buf.subarray(0, this.length) }
}

export class MeshBlobClient {
  /**
   * @param node      FipsNode
   * @param selfKey   this node's public key (identity.publicKey)
   * @param allow     (peerKey) => boolean: the vaults this page may read from; only their segments get through
   */
  constructor(node, selfKey, { allow, tcpConfig, clock = () => Date.now() } = {}) {
    this.stats = { fetched: 0, failed: 0, bytes: 0, retries: 0, lastError: "", dropped: 0 }
    this.stopped = false
    this.allow = allow
    this.clock = clock
    this.shim = ipv6ShimEndpoint(node, selfKey, { allow: k => allow(k), onDrop: () => this.stats.dropped++ })
    this.tcp = new FipsTcpEndpoint(this.shim, MESH_HTTP_PORT, tcpConfig)
  }

  /**
   * GET /<sha256> from `vault` (x-only hex, compressed hex, or npub). Resolves to { bytes, type } with
   * sha256(bytes) === sha256 and `type` a SAFE_TYPES media type or "application/octet-stream"; rejects on any other
   * status, a hash mismatch, a size over MAX_BLOB_BYTES, or `timeoutMs` to connect or without progress. `signal`
   * aborting resets the stream at once (AbortError). `closed` resolves once the stream needs no more segments from
   * the vault (after the polite close lingers), so a caller keeps the vault allowed until then.
   */
  async get(vault, hash, { timeoutMs = DEFAULT_TIMEOUT_MS, onProgress = () => {}, signal } = {}) {
    const key = xOnly(vault)
    if (!key || !this.allow(key)) throw new Error("not one of this relay's vaults")
    const sha = String(hash).toLowerCase()
    if (!SHA256.test(sha)) throw new Error("not a sha256")
    let id, ok = false, closedNow
    const closed = new Promise(r => { closedNow = r })
    try {
      if (signal?.aborted) throw abortError()
      id = await this.#connect("02" + key, this.clock() + timeoutMs, signal)
      let deadline = this.clock() + timeoutMs
      const req = `GET /${sha} HTTP/1.1\r\nHost: ${npubEncode(key)}.fips\r\nAccept: */*\r\nConnection: close\r\n\r\n`
      const out = new TextEncoder().encode(req)
      const buf = new Grow()
      let sent = 0, head, result
      for (;;) {
        const now = this.clock()
        if (this.stopped) throw new Error("FIPS stopped")
        if (signal?.aborted) throw abortError()
        if (now > deadline) throw new Error(sent ? "timed out waiting for the vault" : "timed out connecting to the vault")
        await this.tcp.poll(now)
        const st = await this.tcp.state(id)
        if (st === undefined) throw new Error(sent ? "vault closed the connection" : "vault refused the connection")
        if (st === "established" && sent < out.length) sent += await this.tcp.write(id, out.subarray(sent), now)
        let fresh = false
        for (let b; (b = await this.tcp.read(id, READ_CHUNK, now)).length; ) {
          if (buf.length + b.length > MAX_RAW_BYTES) throw new Error("blob too large")
          buf.push(b)
          fresh = true
        }
        if (fresh) {
          deadline = now + timeoutMs
          onProgress(buf.length)
        }
        const closed = await this.tcp.isReadClosed(id)
        if (fresh || closed) {
          head ??= parseHead(buf.bytes())
          if (head && head.status !== 200) throw new Error(`vault answered ${head.status}`)
          if (head && (result = body(head, buf.bytes(), closed))) break
          if (closed) throw new Error("vault closed the connection before the response")
        }
        await new Promise(r => setTimeout(r, POLL_MS))
      }
      const actual = toHex(sha256(result))
      if (actual !== sha) throw new Error(`hash mismatch: got ${actual.slice(0, 12)}…`)
      ok = true
      this.stats.fetched++
      this.stats.bytes += result.length
      const type = (head.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase()
      return { bytes: result.slice(), type: SAFE_TYPES.test(type) ? type : "application/octet-stream", closed }
    } catch (e) {
      this.stats.failed++
      this.stats.lastError = String(e?.message ?? e).slice(0, 160)
      throw e
    } finally {
      // A finished read closes politely; a failed one is reset so the vault stops sending at once.
      if (id !== undefined) {
        await (ok ? this.tcp.close(id, this.clock()) : this.tcp.abort(id)).catch(() => {})
        if (ok) this.#linger(id).then(closedNow)
        else closedNow()
      } else closedNow()
    }
  }

  /**
   * Open the stream, retrying while the mesh has no route yet. Through the public seeds a session to a vault whose
   * tree parent is the other seed can fail its lookup ("no route", "FSP handshake timeout") and work on a later try.
   */
  async #connect(peer, deadline, signal) {
    for (;;) {
      try {
        return await this.tcp.connect(peer, this.clock())
      } catch (e) {
        if (signal?.aborted) throw abortError()
        if (this.clock() + RETRY_MS >= deadline) throw e
        this.stats.retries++
        this.stats.lastError = String(e?.message ?? e).slice(0, 160)
        await new Promise(r => setTimeout(r, RETRY_MS))
      }
    }
  }

  /** Poll a closing stream in the background until the stack forgets it (or LINGER_MS), so our FIN gets resent. */
  async #linger(id) {
    for (const end = this.clock() + LINGER_MS; !this.stopped && this.clock() < end; ) {
      await this.tcp.poll(this.clock()).catch(() => {})
      const st = await this.tcp.state(id).catch(() => undefined)
      if (st === undefined || st === "time-wait") return
      await new Promise(r => setTimeout(r, 100))
    }
  }

  async stop() {
    this.stopped = true
    await this.tcp.dispose()
    this.shim.close()
  }
}
