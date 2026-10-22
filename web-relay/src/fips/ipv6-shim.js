// Real TCP over the FIPS IPv6 shim (FSP port 256), so the page can reach what a native vault serves on mesh port 80.
// A native vault (fips-v2 stack.rs) terminates mesh IPv6 in smoltcp: plain RFC 9293 TCP with checksums, inside
// FSP datagrams on port 256 whose IPv6 header is compressed (fips src/upper/ipv6_shim.rs, format 0x00):
//   [0x00][ver_tc_flow:4][next_header:1][hop_limit:1][TCP segment]
// Addresses are left out; each side rebuilds them from the session's keys: fd + sha256(x-only key)[0..15].
// @fips/tcp speaks TCP/FIPS instead (checksum and urgent pointer zero, a version option on every SYN). This
// endpoint translates between the two, so FipsTcpEndpoint runs unchanged on top of it.
import { sha256 } from "@noble/hashes/sha2.js"
import { xOnly } from "./owners.js"

export const SHIM_PORT = 256
const FORMAT_COMPRESSED = 0x00
const SHIM_HEADER = 7
const NEXT_TCP = 6
const HOP_LIMIT = 64
const TCP_HEADER = 20
const OPT_EOL = 0, OPT_NOP = 1, OPT_MSS = 2, OPT_FIPS = 254
// TCP/FIPS version 1 (@fips/tcp FIPS_VERSION), required on both SYNs.
const FIPS_VERSION_OPTION = [OPT_FIPS, 4, 1, 0]
const SYN = 0x02, ACK = 0x10, URG = 0x20

const hexBytes = hex => Uint8Array.from(hex.match(/../g), b => parseInt(b, 16))

/** A node's mesh IPv6 address (fips FipsAddress::from_node_addr), from its key as x-only/compressed hex or npub. */
export function meshAddress(key) {
  const x = xOnly(key)
  if (!x) throw new Error("not a FIPS key")
  const out = new Uint8Array(16)
  out[0] = 0xfd
  out.set(sha256(hexBytes(x)).subarray(0, 15), 1)
  return out
}

/** RFC 9293 checksum over the IPv6 pseudo-header and the segment (whose checksum field is read as zero). */
export function tcpChecksum(segment, src, dst) {
  let sum = 0
  const add16 = (hi, lo) => (sum += (hi << 8) | lo)
  for (let i = 0; i < 16; i += 2) add16(src[i], src[i + 1])
  for (let i = 0; i < 16; i += 2) add16(dst[i], dst[i + 1])
  const len = segment.length
  sum += (len >>> 16) & 0xffff
  sum += len & 0xffff
  sum += NEXT_TCP
  for (let i = 0; i < len; i += 2) {
    if (i === 16) continue
    add16(segment[i], i + 1 < len ? segment[i + 1] : 0)
  }
  while (sum > 0xffff) sum = (sum & 0xffff) + (sum >>> 16)
  return ~sum & 0xffff
}

/** The options of a raw TCP header as [kind, bytes] pairs, or undefined if malformed. NOP and EOL are dropped. */
function options(raw) {
  const out = []
  for (let i = 0; i < raw.length; ) {
    const kind = raw[i]
    if (kind === OPT_EOL) break
    if (kind === OPT_NOP) { i++; continue }
    const len = raw[i + 1]
    if (len === undefined || len < 2 || i + len > raw.length) return undefined
    out.push([kind, raw.subarray(i, i + len)])
    i += len
  }
  return out
}

/** A TCP header + payload with the given options (each a byte array), padded with EOL to a 4-byte boundary. */
function rebuild(seg, opts, checksum) {
  const optLen = opts.reduce((n, o) => n + o.length, 0)
  const headerLen = TCP_HEADER + Math.ceil(optLen / 4) * 4
  if (headerLen > 60) return undefined
  const dataOff = (seg[12] >>> 4) * 4
  const payload = seg.subarray(dataOff)
  const out = new Uint8Array(headerLen + payload.length)
  out.set(seg.subarray(0, TCP_HEADER))
  out[12] = ((headerLen / 4) << 4) | (seg[12] & 0x0f)
  let o = TCP_HEADER
  for (const opt of opts) { out.set(opt, o); o += opt.length }
  out.set(payload, headerLen)
  out[16] = out[17] = 0
  out[18] = out[19] = 0
  if (checksum) {
    const c = checksum(out)
    out[16] = c >>> 8
    out[17] = c & 0xff
  }
  return out
}

/** TCP/FIPS segment -> compressed shim payload carrying a checksummed RFC 9293 segment. */
export function encodeShim(fipsSegment, src, dst) {
  const seg = fipsSegment
  if (seg.length < TCP_HEADER) throw new Error("short TCP/FIPS segment")
  const dataOff = (seg[12] >>> 4) * 4
  const opts = options(seg.subarray(TCP_HEADER, dataOff))
  if (!opts) throw new Error("malformed TCP/FIPS options")
  const wire = rebuild(seg, opts.filter(([k]) => k !== OPT_FIPS).map(([, b]) => b), s => tcpChecksum(s, src, dst))
  const out = new Uint8Array(SHIM_HEADER + wire.length)
  out.set([FORMAT_COMPRESSED, 0x60, 0, 0, 0, NEXT_TCP, HOP_LIMIT])
  out.set(wire, SHIM_HEADER)
  return out
}

/**
 * Compressed shim payload -> TCP/FIPS segment, or undefined for anything that isn't a TCP segment with a valid
 * checksum. Only MSS survives from the options (this side never offers window scale, SACK or timestamps, so a
 * peer can't use them); a SYN gets the TCP/FIPS version option @fips/tcp needs.
 */
export function decodeShim(payload, src, dst) {
  if (payload.length < SHIM_HEADER + TCP_HEADER || payload[0] !== FORMAT_COMPRESSED || payload[5] !== NEXT_TCP) return undefined
  const seg = payload.subarray(SHIM_HEADER)
  const dataOff = (seg[12] >>> 4) * 4
  if (dataOff < TCP_HEADER || dataOff > seg.length) return undefined
  if (tcpChecksum(seg, src, dst) !== ((seg[16] << 8) | seg[17])) return undefined
  // Urgent data and the NS/AE bit have no TCP/FIPS form.
  if (seg[13] & URG || seg[12] & 0x01) return undefined
  const opts = options(seg.subarray(TCP_HEADER, dataOff))
  if (!opts) return undefined
  const keep = opts.filter(([k, b]) => k === OPT_MSS && b.length === 4).map(([, b]) => b)
  if (seg[13] & SYN) keep.push(Uint8Array.from(FIPS_VERSION_OPTION))
  return rebuild(seg, keep)
}

/**
 * A FipsDatagramEndpoint (what FipsTcpEndpoint takes) whose datagrams are TCP segments in the IPv6 shim.
 * @param node      FipsNode: inbound shim packets arrive as its "datagram" events, outbound go via sendDatagram
 * @param selfKey   this node's public key (compressed or x-only bytes, or hex)
 * @param allow     (peerKey) => boolean: segments from anyone else are dropped before the TCP stack sees them
 * @param acceptSyn false for a client-only endpoint: a bare SYN is dropped, so nothing here ever listens
 */
export function ipv6ShimEndpoint(node, selfKey, { allow = () => false, acceptSyn = false, onDrop = () => {} } = {}) {
  const self = meshAddress(typeof selfKey === "string" ? selfKey : [...selfKey].map(b => b.toString(16).padStart(2, "0")).join(""))
  const handlers = new Map()
  const addrs = new Map()
  const addrOf = key => {
    let a = addrs.get(key)
    if (!a) {
      a = meshAddress(key)
      if (addrs.size > 256) addrs.clear()
      addrs.set(key, a)
    }
    return a
  }
  const off = node.on("datagram", async d => {
    if (d.dstPort !== SHIM_PORT || d.srcPort !== SHIM_PORT) return
    if (!xOnly(d.src) || !allow(d.src)) return onDrop("stranger")
    const seg = decodeShim(d.payload, addrOf(d.src), self)
    if (!seg) return onDrop("not a valid TCP segment")
    if (!acceptSyn && seg[13] & SYN && !(seg[13] & ACK)) return onDrop("unsolicited SYN")
    // A listening endpoint takes what is sent to its port; a client endpoint takes what comes from its remote port.
    // Never both: a page reading port 80 from a vault while serving its own port 80 runs one of each on this node,
    // and a segment handed to the wrong stack is answered with an RST that kills the other's stream.
    const handler = handlers.get(acceptSyn ? (seg[2] << 8) | seg[3] : (seg[0] << 8) | seg[1])
    if (!handler) return onDrop("no endpoint")
    try {
      // @fips/tcp keys connections by the exact peer string. A session the vault opened reports its key with its
      // real parity ("03…"), while connect() dialed "02…": hand over the even form, as the page dials.
      await handler({ src: "02" + xOnly(d.src), srcPort: SHIM_PORT, dstPort: SHIM_PORT, payload: seg })
    } catch (e) {
      onDrop(String(e?.message ?? e))
    }
  })
  return {
    /** `port` is the TCP port (FipsTcpEndpoint passes its service port), not an FSP one. */
    registerService(port, handler) {
      handlers.set(port, handler)
      return () => handlers.get(port) === handler && handlers.delete(port)
    },
    sendDatagram: ({ dst, payload }) => node.sendDatagram({ dst, srcPort: SHIM_PORT, dstPort: SHIM_PORT, payload: encodeShim(payload, self, addrOf(dst)) }),
    close: () => { off?.(); handlers.clear() },
  }
}
