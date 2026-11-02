// The versions of one of the user's lists that can be found (Settings › Recover a List): what this browser's vault
// kept (its /lists history route, haven-go list_history.go), the Following Backup copies for kind 3, and whatever
// the user's relays and the profile index still hold (most keep only the newest; some keep history). Only the user's
// own, validly signed copies count, since a merge republishes their entries as the user's. Nothing here signs.
import { verifyEvent } from "nostr-tools/pure"
import { pool, uniq, PROFILE_RELAYS } from "./pool.js"
import { MAX_SKEW } from "./follows.js"
import { snapshotStore } from "./follow-backup.js"
import { MERGE_KINDS } from "./list-version-merge.js"

const now = () => Math.floor(Date.now() / 1000)
const pick = ({ id, pubkey, created_at, kind, tags, content, sig }) => ({ id, pubkey, created_at, kind, tags, content, sig })

/** The user's own copy of `kind`: signed by them (checked on a fresh copy: verifyEvent trusts a flag an object may
 *  carry), not dated MAX_SKEW or more ahead, so one bad clock can't pose as the newest version. */
export function ownVersion(ev, me, kind, at = now()) {
  if (ev?.kind !== kind || ev.pubkey !== me || !Array.isArray(ev.tags) || typeof ev.content !== "string") return false
  if (!(ev.created_at < at + MAX_SKEW)) return false
  try { return verifyEvent(pick(ev)) } catch { return false }
}

/** Newest first; the same time: the lower id first, as NIP-01 relays keep it. */
export const byNewest = (a, b) => b.created_at - a.created_at || (a.id < b.id ? -1 : 1)

/**
 * Every version of `kind` found, newest first, each once, with where it was found (`from`: "vault", "browser",
 * "relays"). `sources` replaces the readers, for tests. -> [{ ...event, from: [..] }]
 */
export async function findVersions(ctx, kind, { sources, at = now() } = {}) {
  const me = ctx.session.pubkey
  const filter = { kinds: [kind], authors: [me] }
  const read = sources ?? {
    vault: () => Promise.all([ctx.vault.lists?.query(filter) ?? [], ctx.vault.outbox.query(filter)]).then(a => a.flat()),
    browser: () => (kind === 3 ? snapshotStore(me).all() : []),
    relays: () => pool.querySync(uniq([...ctx.account.relays.read, ...ctx.account.relays.write, ...PROFILE_RELAYS]), { ...filter, limit: 50 }, { maxWait: 8000 }),
  }
  const by = new Map()
  await Promise.all(Object.entries(read).map(async ([from, get]) => {
    const evs = await Promise.resolve().then(get).catch(() => [])
    for (const ev of evs ?? []) {
      if (!ownVersion(ev, me, kind, at)) continue
      const had = by.get(ev.id)
      if (had) { if (!had.from.includes(from)) had.from.push(from) } else by.set(ev.id, { ...pick(ev), from: [from] })
    }
  }))
  return [...by.values()].sort(byNewest)
}

/**
 * For the page's first view: each mergeable list with how many versions this browser's vault holds and when the
 * newest is from. Only the vault is asked (fast, offline); a list's own page asks the relays too.
 * -> [{ kind, name, versions, newest }]
 */
export async function listOverview(ctx, { at = now() } = {}) {
  const me = ctx.session.pubkey
  const kinds = MERGE_KINDS.map(k => k.kind)
  const evs = await (ctx.vault.lists?.query({ kinds, authors: [me] }) ?? Promise.resolve([])).catch(() => [])
  return MERGE_KINDS.map(({ kind, name }) => {
    const mine = evs.filter(e => ownVersion(e, me, kind, at))
    return { kind, name, versions: new Set(mine.map(e => e.id)).size, newest: mine.reduce((n, e) => Math.max(n, e.created_at), 0) }
  })
}
