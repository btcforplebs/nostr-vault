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
