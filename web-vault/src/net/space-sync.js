// The desktop layout (Your space's panels and the left rail's favourites, desktop/space/space-layout.js) kept on the
// user's own account, so another browser, and later the iPad, opens with the same one (RESEARCH plan phase 4, Logen
// 2026-11-03: synced through his vault). One NIP-78 app-data event, the way the wallet backup is kept (iOS
// NWCBackup.swift):
//   kind 30078, tags ["d", SYNC_D], ["client", "Nostr Vault"], ["encryption", "nip44"]
//   content: the layout's JSON, NIP-44 encrypted to the account's own key
// It is replaceable, so each send takes the place of the last. It goes out like any other post (actions.js
// publishAction: the user's write relays, then the in-page vault's outbox) and is read back from the outbox and those
// relays. The newest edit wins, by the layout's own `at` (the moment of the edit), not by when the event was signed.
import { publishAction } from "./actions.js"
import { pool, uniq } from "./pool.js"
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

/** A layout's text read back -> the layout object, or null when it is not one. */
export function parseLayout(text) {
  try {
    const l = JSON.parse(text)
    return l && typeof l === "object" && Array.isArray(l.panels) && Number.isFinite(l.at) ? l : null
  } catch { return null }
}

/** Which layout to keep: `remote` when its edit is newer than `local`'s, else `local` (the same object). */
export const newerLayout = (local, remote) => (remote && Number.isFinite(remote.at) && remote.at > (local?.at ?? 0) ? remote : local)

/** Seal and send the layout. A read-only sign-in can't, and sends nothing. -> the event, or null. `publish` is for
 *  tests. */
export async function pushLayout(ctx, layout, { publish = publishAction } = {}) {
  if (ctx.signer?.readOnly || !ctx.signer?.crypto) return null
  const me = ctx.session.pubkey
  const sealed = await ctx.signer.crypto.encrypt(me, JSON.stringify(layout))
  const { event } = await publish(ctx, layoutTemplate(sealed))
  return event
}

/** The newest layout this account saved, from the in-page vault and the user's relays, opened; null when there is
 *  none or it can't be opened. `query` is for tests. */
export async function pullLayout(ctx, { query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  if (!ctx.signer?.crypto) return null
  const me = ctx.session.pubkey
  const filter = { kinds: [SYNC_KIND], authors: [me], "#d": [SYNC_D], limit: 5 }
  const relays = uniq([...(ctx.account?.relays?.write ?? []), ...(ctx.account?.relays?.read ?? [])])
  const [local, net] = await Promise.all([
    ctx.vault?.outbox?.query(filter).catch(() => []) ?? [],
    relays.length ? query(relays, filter, { maxWait: 6000 }).catch(() => []) : [],
  ])
  const ev = newestEvent([...local, ...net], me)
  if (!ev) return null
  // Kept in the in-page vault too, so the next look finds it there first.
  if (!local.some(e => e.id === ev.id)) ctx.vault?.outbox?.event(ev).catch(() => {})
  try { return parseLayout(await ctx.signer.crypto.decrypt(me, ev.content)) } catch { return null }
}
