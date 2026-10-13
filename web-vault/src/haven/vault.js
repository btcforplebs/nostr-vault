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
  })
  const open = route => new HavenClient(haven.conn(`ui${route.replace("/", "-")}`, { mode: "nip01", route, owner: true }), {
    auth: challenge => finalizeEvent(makeAuthEvent(`wss://${RELAY_HOST}${route}`, challenge), sk),
  })
  return { haven, owners, outbox: open("/"), feed: open("/feed"), loadMs, startMs: Date.now() - t0 - loadMs }
}
