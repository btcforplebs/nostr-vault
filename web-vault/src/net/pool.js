// The network side: nostr-tools SimplePool to the user's relays. The UI never renders from here directly;
// what comes in is written to the in-page Haven and read back from it.
import { SimplePool } from "nostr-tools/pool"

export const pool = new SimplePool({ enablePing: true, enableReconnect: true })

export const DEFAULT_RELAYS = ["wss://relay.damus.io", "wss://nos.lol", "wss://relay.primal.net"]
// relay.nostr.band stopped answering (no EOSE, every query held to its timeout) on 2026-10-13.
export const PROFILE_RELAYS = ["wss://purplepag.es"]

/** Read and write relays from a kind 10002 event (NIP-65), falling back to the defaults. */
export function relayLists(ev) {
  const read = [], write = []
  for (const t of ev?.tags ?? []) {
    if (t[0] !== "r" || !/^wss?:\/\//.test(t[1] ?? "")) continue
    const url = t[1].replace(/\/+$/, "")
    if (t[2] !== "write") read.push(url)
    if (t[2] !== "read") write.push(url)
  }
  return { read: read.length ? read : DEFAULT_RELAYS, write: write.length ? write : DEFAULT_RELAYS }
}

export const uniq = a => [...new Set(a)]

// Where the iPhone app sends a new note: its Write list, or this list when that is empty
// (HavenConfig.fallbackWriteRelays / RelayConfiguration.directBroadcastRelays).
export const BROADCAST_RELAYS = ["wss://relay.btcforplebs.com", "wss://relay.damus.io", "wss://relay.snort.social"]
// Hosts the iPhone app strips from saved lists because they stopped answering (HavenConfig.deadRelayHosts).
export const DEAD_RELAY_HOSTS = new Set(["nos.lol", "nostr.mom", "offchain.pub"])

const hostOf = url => { try { return new URL(url).hostname.toLowerCase() } catch { return "" } }
const loopbackHost = h => { h = h.replace(/^\[|\]$/g, "").toLowerCase(); return h === "localhost" || h === "::1" || /^127\./.test(h) }
/** A relay on the machine the browser runs on (the Mac's own vault relay, ws://localhost:3355). */
export const isLoopback = url => loopbackHost(hostOf(url))

/**
 * The relays a new note goes to: the write list plus the iPhone app's broadcast set, so a short or half-dead
 * write list still reaches the wider network. Dead hosts are dropped as the iPhone app drops them. A loopback
 * relay is only reachable from a page open on that same machine, so it is kept only there and marked local.
 * -> { network: [url], local: [url] }
 */
export function publishRelays(writeRelays, pageHost = globalThis.location?.hostname ?? "") {
  const urls = uniq([...writeRelays, ...BROADCAST_RELAYS].map(u => u.trim().replace(/\/+$/, "")).filter(u => /^wss?:\/\//.test(u)))
  const live = urls.filter(u => !DEAD_RELAY_HOSTS.has(hostOf(u)))
  return { network: live.filter(u => !isLoopback(u)), local: loopbackHost(pageHost) ? live.filter(isLoopback) : [] }
}
