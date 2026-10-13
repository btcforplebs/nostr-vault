// The in-page Haven, started for the signed-in user. The UI talks to it in process: one NIP-01 stream per
// route (havenConn, no socket). Its owner is the user; the page's device key and paired FIPS vaults are
// whitelisted. /feed reads need NIP-42 AUTH from a whitelisted key, answered with the device key, so
// reading the local cache never asks the user's signer and works offline.
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { bytesToHex, hexToBytes } from "nostr-tools/utils"
import { npubEncode } from "nostr-tools/nip19"
import { makeAuthEvent } from "nostr-tools/nip42"
import { loadHaven } from "../../../web-relay/src/haven/haven.js"
import { HavenClient } from "../../../web-relay/src/haven/client.js"
import { loadOwners } from "../../../web-relay/src/fips/owners.js"
import { clearSession } from "../session.js"

// Haven's ServiceURL is https://RELAY_HOST/<route>; NIP-42 compares the AUTH relay tag against it as wss.
const RELAY_HOST = "vault.local"
const DEVICE_KEY = "nv-device-sk"
const WASM = new URL("../../../web-relay/public/haven.wasm", import.meta.url)

/** This browser's own key: answers Haven's AUTH. Not a user key, and it never signs anything public. */
export function deviceKey(storage = localStorage) {
  let hex = storage.getItem(DEVICE_KEY)
  if (!hex) storage.setItem(DEVICE_KEY, (hex = bytesToHex(generateSecretKey())))
  return hexToBytes(hex)
}

export async function startVault({ pubkey, log = () => {} }) {
  const owners = loadOwners({ log })
  const sk = deviceKey()
  const t0 = Date.now()
  const haven = await loadHaven(WASM)
  const loadMs = Date.now() - t0
  await haven.start({
    ownerNpub: npubEncode(pubkey),
    whitelist: [getPublicKey(sk), ...owners].map(k => npubEncode(k)),
    env: { RELAY_URL: RELAY_HOST },
    // One set of stores per account, so a second account on this browser never opens the first one's data.
    storePrefix: pubkey,
  })
  const open = route => new HavenClient(haven.conn(`ui${route.replace("/", "-")}`, { mode: "nip01", route, owner: true }), {
    auth: challenge => finalizeEvent(makeAuthEvent(`wss://${RELAY_HOST}${route}`, challenge), sk),
  })
  return { haven, owners, outbox: open("/"), feed: open("/feed"), loadMs, startMs: Date.now() - t0 - loadMs }
}

// Haven's route databases (haven-go/store_wasm.go), per account since storePrefix. The unprefixed ones are from
// before that, when every account on this browser shared them; this page has its own origin, so they're its own.
const ROUTES = ["private", "chat", "outbox", "inbox", "blossom", "feed"]
const storeNames = pubkey => ROUTES.flatMap(r => [`haven:${pubkey}:${r}`, `haven:${r}`])
// Everything else this page keeps: the device key, the FIPS relay key and paired vaults, and the activity log.
const LOCAL_KEYS = [DEVICE_KEY, "fips-relay-key", "fips-owners", "nv-log"]

/** Sign-out: stop Haven, delete its stores, and drop the session, the device and FIPS keys and the log. -> { failed } */
export async function forgetThisBrowser({ vault, pubkey, storage = localStorage, idb = indexedDB, waitMs = 5000 }) {
  await vault?.haven.stop().catch(() => {})
  clearSession(storage)
  for (const k of LOCAL_KEYS) storage.removeItem(k)
  const failed = []
  await Promise.all(storeNames(pubkey).map(name => new Promise(resolve => {
    // "blocked" means a connection is still open; the delete finishes when it closes, so wait a little for that.
    const timer = setTimeout(() => { failed.push(name); resolve() }, waitMs)
    const req = idb.deleteDatabase(name)
    req.onsuccess = () => { clearTimeout(timer); resolve() }
    req.onerror = () => { clearTimeout(timer); failed.push(name); resolve() }
  })))
  return { failed }
}
