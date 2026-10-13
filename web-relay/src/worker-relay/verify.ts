import { schnorr } from "@noble/curves/secp256k1.js"
import { sha256 } from "@noble/hashes/sha2.js"
import { bytesToHex, hexToBytes } from "@noble/hashes/utils.js"
import type { NostrEvent } from "./types"

const HEX64 = /^[0-9a-f]{64}$/
const HEX128 = /^[0-9a-f]{128}$/
const enc = new TextEncoder()

/**
 * NIP-01 check every event must pass before it is stored: well-formed fields,
 * id == sha256 of the canonical serialization, and a valid BIP-340 signature.
 * Returns a NIP-01 OK message ("invalid: ...") when it fails, undefined when it passes.
 */
export function rejectReason(ev: NostrEvent): string | undefined {
  if (!ev || typeof ev !== "object") return "invalid: not an event"
  if (!HEX64.test(ev.id) || !HEX64.test(ev.pubkey) || !HEX128.test(ev.sig)) return "invalid: bad id, pubkey or sig encoding"
  if (!Number.isInteger(ev.kind) || ev.kind < 0 || ev.kind > 65535) return "invalid: bad kind"
  if (!Number.isInteger(ev.created_at) || ev.created_at < 0) return "invalid: bad created_at"
  if (typeof ev.content !== "string") return "invalid: bad content"
  if (!Array.isArray(ev.tags) || !ev.tags.every(t => Array.isArray(t) && t.every(v => typeof v === "string"))) return "invalid: bad tags"
  const hash = sha256(enc.encode(JSON.stringify([0, ev.pubkey, ev.created_at, ev.kind, ev.tags, ev.content])))
  if (bytesToHex(hash) !== ev.id) return "invalid: id does not match event hash"
  try {
    if (!schnorr.verify(hexToBytes(ev.sig), hash, hexToBytes(ev.pubkey))) return "invalid: bad signature"
  } catch {
    return "invalid: bad signature"
  }
  return undefined
}
