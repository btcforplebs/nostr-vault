// Stand-in for what a native vault serves on mesh port 80: HTTP over real TCP in the FIPS IPv6 shim, answering
// GET /<sha256>[.ext] from a map of blobs, the way the vault's relay answers Blossom reads. Used by the tests and
// by tools/blob-vault-sim.mjs. Not shipped in the page.
import { FipsTcpEndpoint } from "@fips/tcp"
import { ipv6ShimEndpoint } from "../../src/fips/ipv6-shim.js"
import { MESH_HTTP_PORT } from "../../src/fips/blob-get.js"

/**
 * @param node   FipsNode (or a test node with on("datagram") + sendDatagram)
 * @param selfKey this node's public key
 * @param blobs  Map<sha256 hex, { bytes, type }>
 * @param chunked answer with Transfer-Encoding: chunked instead of Content-Length
 */
export function meshHttpVault(node, selfKey, blobs, { chunked = false, clock = () => Date.now(), log = () => {} } = {}) {
  const shim = ipv6ShimEndpoint(node, selfKey, { allow: () => true, acceptSyn: true })
  const tcp = new FipsTcpEndpoint(shim, MESH_HTTP_PORT)
  const conns = new Map()
  const stats = { requests: 0, served: 0, notFound: 0 }
  const respond = path => {
    const m = path.toLowerCase().match(/^\/([0-9a-f]{64})(\.[a-z0-9]+)?$/)
    const blob = m && blobs.get(m[1])
    if (!blob) {
      stats.notFound++
      return new TextEncoder().encode("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    }
    stats.served++
    const type = blob.type || "application/octet-stream"
    if (!chunked) {
      const head = new TextEncoder().encode(`HTTP/1.1 200 OK\r\nContent-Type: ${type}\r\nContent-Length: ${blob.bytes.length}\r\nConnection: close\r\n\r\n`)
      return concat([head, blob.bytes])
    }
    const parts = [new TextEncoder().encode(`HTTP/1.1 200 OK\r\nContent-Type: ${type}\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n`)]
    for (let o = 0; o < blob.bytes.length; o += 4000) {
      const c = blob.bytes.subarray(o, o + 4000)
      parts.push(new TextEncoder().encode(c.length.toString(16) + "\r\n"), c, new TextEncoder().encode("\r\n"))
    }
    parts.push(new TextEncoder().encode("0\r\n\r\n"))
    return concat(parts)
  }
  const tick = async () => {
    const now = clock()
    await tcp.poll(now)
    for (let id; (id = await tcp.accept()) !== undefined; ) conns.set(id, { head: "", out: undefined, sent: 0 })
    for (const [id, c] of conns) {
      if ((await tcp.state(id)) === undefined) { conns.delete(id); continue }
      if (!c.out) {
        for (let b; (b = await tcp.read(id, 65536, now)).length; ) c.head += new TextDecoder().decode(b)
        const end = c.head.indexOf("\r\n\r\n")
        if (end < 0) continue
        stats.requests++
        const path = c.head.split("\r\n")[0].split(" ")[1] ?? ""
        log(`GET ${path.slice(0, 20)}… from ${(await tcp.peer(id))?.slice(0, 12)}`)
        c.out = respond(path)
      }
      while (c.sent < c.out.length) {
        const n = await tcp.write(id, c.out.subarray(c.sent), now)
        if (!n) break
        c.sent += n
      }
      if (c.sent === c.out.length && !c.closing) {
        c.closing = true
        await tcp.close(id, now)
      }
    }
  }
  return { tcp, stats, tick, stop: async () => { await tcp.dispose(); shim.close() } }
}

function concat(parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let o = 0
  for (const p of parts) { out.set(p, o); o += p.length }
  return out
}
