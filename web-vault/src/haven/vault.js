// The in-page Haven, started for the signed-in user. The UI talks to it in process: one NIP-01 stream per
// route (havenConn, no socket). Its owner is the user and the page's device key is whitelisted. Paired FIPS vaults
// are not: their mesh keys are network identities, gated by the FIPS layer (web-relay/src/fips), and never go
// into Haven as Nostr identities. /feed reads need NIP-42 AUTH from a whitelisted key, answered with the device key, so
// reading the local cache never asks the user's signer and works offline.
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { bytesToHex, hexToBytes } from "nostr-tools/utils"
import { npubEncode } from "nostr-tools/nip19"
import { makeAuthEvent } from "nostr-tools/nip42"
import { loadHaven } from "../../../web-relay/src/haven/haven.js"
import { HavenClient } from "../../../web-relay/src/haven/client.js"
import { loadOwners } from "../../../web-relay/src/fips/owners.js"
import { VAULT_NS, pageStorage } from "../../../web-relay/src/page-storage.js"
import { clearSession } from "../session.js"

// Haven's ServiceURL is https://RELAY_HOST/<route>; NIP-42 compares the AUTH relay tag against it as wss.
const RELAY_HOST = "vault.local"
const DEVICE_KEY = "nv-device-sk"
const WASM = new URL("../../../web-relay/public/haven.wasm", import.meta.url)
// FIPS keys (this browser's mesh key, paired vaults) under VAULT_NS: /relay/ is the same origin and keeps its own.
const FIPS_ITEMS = ["fips-relay-key", "fips-owners"]
export const fipsStorage = (storage = localStorage) => pageStorage(storage, VAULT_NS)

/** This browser's own key: answers Haven's AUTH. Not a user key, and it never signs anything public. */
export function deviceKey(storage = localStorage) {
  let hex = storage.getItem(DEVICE_KEY)
  if (!hex) storage.setItem(DEVICE_KEY, (hex = bytesToHex(generateSecretKey())))
  return hexToBytes(hex)
}

export async function startVault({ pubkey, log = () => {} }) {
  const owners = loadOwners({ log, account: pubkey, storage: fipsStorage() })
  const sk = deviceKey()
  const t0 = Date.now()
  const haven = await loadHaven(WASM)
  const loadMs = Date.now() - t0
  await haven.start({
    ownerNpub: npubEncode(pubkey),
    whitelist: [npubEncode(getPublicKey(sk))],
    env: { RELAY_URL: RELAY_HOST },
    // One set of stores per account, so a second account on this browser never opens the first one's data.
    storePrefix: pubkey,
  })
  const open = route => new HavenClient(haven.conn(`ui${route.replace("/", "-")}`, { mode: "nip01", route, owner: true }), {
    auth: challenge => finalizeEvent(makeAuthEvent(`wss://${RELAY_HOST}${route}`, challenge), sk),
  })
  return { haven, owners, outbox: open("/"), feed: open("/feed"), loadMs, startMs: Date.now() - t0 - loadMs }
}

// Haven's route databases (haven-go/store_wasm.go) for this account: "haven:<pubkey>:<route>" (storePrefix).
// Sign-out deletes every database the browser lists under that prefix, so a route added in Go is wiped too, and
// the unprefixed "haven:<route>" ones from before storePrefix: nothing opens those any more (the vault uses the
// pubkey, /relay/ uses "relay"), and they may still hold old notes, DMs and files. Never "haven:relay:<route>":
// /relay/ is the same origin, so its stores are in this IndexedDB too. Never another account's either:
// "haven:<other pubkey>:<route>". The list is the fallback for browsers without indexedDB.databases() (Firefox < 126).
// "blobs" is not a route: it holds Blossom's files themselves (haven-go/blobfs_wasm.go). Nor is "drafts": Compose's
// unsent notes (ComposeScreen idbDrafts), only ever under the pubkey, named like the routes so this wipe takes them.
const ROUTES = ["private", "chat", "outbox", "inbox", "blossom", "feed", "blobs"]
export async function storeNames(pubkey, idb = indexedDB) {
  const known = [...ROUTES.flatMap(r => [`haven:${pubkey}:${r}`, `haven:${r}`]), `haven:${pubkey}:drafts`]
  const mine = new RegExp(`^haven:(${pubkey}:)?[0-9A-Za-z_-]+$`) // pubkey is 64 lowercase hex: nothing to escape
  const listed = idb.databases ? (await idb.databases().catch(() => [])).map(d => d.name).filter(n => mine.test(n ?? "")) : []
  return [...new Set([...known, ...listed])]
}
// Everything else this page keeps: the device key, its FIPS key and paired vaults, and the activity log. The bare
// FIPS keys are from before the page prefixes: a vault that paired through its Relay screen left them, and nothing
// reads them now unless /relay/ is opened again (src/page-storage.js migrateRelayKeys), which would then re-pair.
const LOCAL_KEYS = [DEVICE_KEY, ...FIPS_ITEMS.map(k => VAULT_NS + k), ...FIPS_ITEMS, "nv-log"]
const SESSION_KEY = "nv-session"

/** Sign-out: stop Haven, delete its stores, and drop the session, the device and FIPS keys and the log. -> { failed } */
export async function forgetThisBrowser({ vault, pubkey, storage = localStorage, idb = indexedDB, waitMs = 5000 }) {
  await vault?.haven.stop().catch(() => {})
  // Removing the session is also what tells this page's other tabs to stop (see onSignedOutElsewhere).
  clearSession(storage)
  for (const k of LOCAL_KEYS) storage.removeItem(k)
  const failed = []
  await Promise.all((await storeNames(pubkey, idb)).map(name => new Promise(resolve => {
    // "blocked" means a connection is still open (another tab still stopping); the delete finishes when it closes.
    const timer = setTimeout(() => { failed.push(name); resolve() }, waitMs)
    const req = idb.deleteDatabase(name)
    req.onsuccess = () => { clearTimeout(timer); resolve() }
    req.onerror = () => { clearTimeout(timer); failed.push(name); resolve() }
  })))
  // Another tab that was still running while the stores were deleted may have written a key back; drop it again.
  for (const k of LOCAL_KEYS) storage.removeItem(k)
  return { failed: failed.sort() }
}

/**
 * Calls `onGone` once when another tab of this page signs out, or signs in as someone else, so this tab can stop
 * Haven (letting that tab's deletes finish) and reload instead of re-creating what was deleted. -> unsubscribe
 */
export function onSignedOutElsewhere(pubkey, onGone, target = globalThis) {
  let fired = false
  const f = e => {
    if (fired || (e.key !== SESSION_KEY && e.key !== null)) return // key null: storage.clear()
    let next = null
    try { next = JSON.parse(e.newValue ?? "null")?.pubkey ?? null } catch {}
    if (next === pubkey) return
    fired = true
    onGone()
  }
  target.addEventListener("storage", f)
  return () => target.removeEventListener("storage", f)
}
