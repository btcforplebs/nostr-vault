// The desktop layout (Your space's panels and the left rail's pins, desktop/space/space-layout.js) kept on the user's
// own account, so another browser and the iPad open with the same one (docs/SPACE_LAYOUT.md "Synced through the
// user's own account"; Logen 2026-11-03). One NIP-78 app-data event, the way the wallet backup is kept (iOS
// NWCBackup.swift):
//   kind 30078, tags ["d", SYNC_D], ["client", "Nostr Vault"], ["encryption", "nip44"]
//   content: the layout's JSON, NIP-44 encrypted to the account's own key
// It is replaceable, so each send takes the place of the last. It goes out like any other post (actions.js
// publishAction: the user's write relays, then the in-page vault's outbox) and is read back from the outbox and those
// relays. The newest edit wins, by the layout's own `at` (the moment of the edit), not by when the event was signed.
import { publishAction } from "./actions.js"
import { pool, uniq, publishRelays } from "./pool.js"
import { SYNC_D } from "../desktop/space/space-layout.js"

export const SYNC_KIND = 30078
export { SYNC_D }
export const SYNC_TAGS = [["d", SYNC_D], ["client", "Nostr Vault"], ["encryption", "nip44"]]

/** Whether an event is this account's layout slot. */
export const isLayoutEvent = (ev, me) => ev?.kind === SYNC_KIND && ev.pubkey === me && (ev.tags ?? []).some(t => t[0] === "d" && t[1] === SYNC_D)

/** The unsigned event for a layout, its content already sealed. */
export const layoutTemplate = (sealed, at = Math.floor(Date.now() / 1000)) =>
  ({ kind: SYNC_KIND, created_at: at, tags: SYNC_TAGS.map(t => [...t]), content: sealed })

/** The newest of these events (by created_at, then id), or null. */
export function newestEvent(events, me) {
  let best = null
  for (const ev of events) {
    if (!isLayoutEvent(ev, me)) continue
    if (!best || ev.created_at > best.created_at || (ev.created_at === best.created_at && ev.id > best.id)) best = ev
  }
  return best
}

/** A layout's text read back -> the parsed object (normalize decides what it is worth), or null when it isn't one. */
export function parseLayout(text) {
  try {
    const l = JSON.parse(text)
    return l && typeof l === "object" && !Array.isArray(l) ? l : null
  } catch { return null }
}

/** Which layout to keep: `remote` when its edit is newer than `local`'s; equal or older, `local` (the same object). */
export const newerLayout = (local, remote) => (remote && Number.isFinite(remote.at) && remote.at > (local?.at ?? 0) ? remote : local)

/** Whether sealed text is not the layout in the clear: never publish plaintext (docs "Write"). */
export const looksSealed = (sealed, plain) => {
  if (typeof sealed !== "string" || !sealed || sealed === plain || sealed.includes(plain)) return false
  try { JSON.parse(sealed); return false } catch { return true }
}

/** Seal and send the layout. A read-only sign-in can't, and sends nothing. -> the event, or null. `publish` is for
 *  tests. */
export async function pushLayout(ctx, layout, { publish = publishAction } = {}) {
  if (ctx.signer?.readOnly || !ctx.signer?.crypto) return null
  const me = ctx.session.pubkey
  const plain = JSON.stringify(layout)
  const sealed = await ctx.signer.crypto.encrypt(me, plain)
  if (!looksSealed(sealed, plain)) throw new Error("The layout didn't come back encrypted, so it wasn't sent")
  // The account may have changed while the signer sealed it: the layout belongs to the one that made the edit.
  if (ctx.stillMe && !ctx.stillMe(me)) return null
  const { event } = await publish(ctx, layoutTemplate(sealed))
  return event
}

/** Whether any of these relays is connected now (nostr-tools' listConnectionStatus, keyed by normalised URL). */
const anyConnected = urls => {
  const status = pool.listConnectionStatus?.()
  if (!status) return true // can't tell: don't call it a failure
  const norm = u => String(u).trim().replace(/\/+$/, "").toLowerCase()
  const up = new Set([...status].filter(([, ok]) => ok).map(([u]) => norm(u)))
  return urls.some(u => up.has(norm(u)))
}

/** The relays the layout is read from: the ones a send goes to (publishRelays, which falls back to the defaults when
 *  the user lists no write relays), and the user's read relays. */
export const syncRelays = ctx => {
  const { network, local } = publishRelays(ctx.account?.relays?.write ?? [])
  return uniq([...network, ...local, ...(ctx.account?.relays?.read ?? [])])
}

/** The newest layout this account saved, from the in-page vault and the user's relays, opened (not yet normalized):
 *  { state: "ok", layout } | { state: "none" } (none saved, or no key to read it) | { state: "unreadable" } (the
 *  signer refused, or the ciphertext or JSON is bad: keep this browser's copy and don't write over it) |
 *  { state: "failed" } (nothing in the in-page vault and no relay answered: unknown, so nothing may be sent yet).
 *  `query` and `connected` are for tests. */
export async function pullLayout(ctx, { query = (r, f, o) => pool.querySync(r, f, o), connected = anyConnected } = {}) {
  if (!ctx.signer?.crypto) return { state: "none" }
  const me = ctx.session.pubkey
  const filter = { kinds: [SYNC_KIND], authors: [me], "#d": [SYNC_D], limit: 5 }
  const relays = syncRelays(ctx)
  let failed = !relays.length
  const [local, net] = await Promise.all([
    ctx.vault?.outbox?.query(filter).catch(() => []) ?? [],
    relays.length ? query(relays, filter, { maxWait: 6000 }).catch(() => { failed = true; return [] }) : [],
  ])
  const ev = newestEvent([...local, ...net], me)
  // Nothing found: "none" only when a relay actually answered (it is connected, so its EOSE came or it timed out
  // while up); every relay down or refused is not knowing, not an empty vault.
  if (!ev) return !failed && connected(relays) ? { state: "none" } : { state: "failed" }
  // Kept in the in-page vault too, so the next look finds it there first.
  if (!local.some(e => e.id === ev.id)) ctx.vault?.outbox?.event(ev).catch(() => {})
  let layout = null
  try { layout = parseLayout(await ctx.signer.crypto.decrypt(me, ev.content)) } catch {}
  return layout ? { state: "ok", layout } : { state: "unreadable" }
}
