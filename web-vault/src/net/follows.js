// Follow / Unfollow: a new kind 3 built on the newest one this browser can find, with the iPhone app's wipe guard
// (ContactManager.mayPublish). A kind 3 replaces the whole list, so a stale or missing base would wipe the follows:
// nothing is published unless a list was found, and never one that drops most of what the user had.
import { pool, publishRelays, PROFILE_RELAYS, uniq } from "./pool.js"
import { checkSigned } from "./sync.js"

const HEX = /^[0-9a-f]{64}$/
const now = () => Math.floor(Date.now() / 1000)

/** The followed pubkeys in a kind 3, in order, once each. */
export const followsOf = ev => uniq((ev?.tags ?? []).filter(t => t[0] === "p" && HEX.test(t[1] ?? "")).map(t => t[1]))

/** The newest of these kind 3s by this author (ties: the lower id, as NIP-01 replaceable events). */
export function newestList(lists, pubkey) {
  let best
  for (const ev of lists) {
    if (ev?.kind !== 3 || ev.pubkey !== pubkey) continue
    if (!best || ev.created_at > best.created_at || (ev.created_at === best.created_at && ev.id < best.id)) best = ev
  }
  return best
}

/**
 * The newest kind 3 of `pubkey` from the vault (Haven's outbox), the network and `known` (the list the app holds).
 * Nothing found here is written to the vault: a list the guard refuses must not become the app's follows.
 * `query` is for tests.
 * -> { base, seen: [kind 3] }
 */
export async function findLatestList({ vault, pubkey, relays, known, query = (r, f, o) => pool.querySync(r, f, o) }) {
  const filter = { kinds: [3], authors: [pubkey] }
  const [local, net] = await Promise.all([
    vault.outbox.query(filter).catch(() => []),
    query(uniq([...relays, ...PROFILE_RELAYS]), filter, { maxWait: 6000 }).catch(() => []),
  ])
  const seen = [...local, ...net, ...(known ? [known] : [])].filter(ev => ev?.kind === 3 && ev.pubkey === pubkey)
  return { base: newestList(seen, pubkey), seen }
}

/** The tags of `base` with `target` followed or not. Every other tag, and the content, are kept as they were. */
export function editedTags(base, target, follow) {
  const tags = (base?.tags ?? []).filter(t => !(t[0] === "p" && t[1] === target))
  if (follow) tags.push(["p", target])
  return tags
}

/**
 * Why this list may not be published, or "" if it may. The rules, in order:
 *  - no base list found: refuse (a missing list must never be replaced by a one-follow list);
 *  - the result must keep every follow of the base except the one being unfollowed;
 *  - nothing that would be empty, unless it is a single unfollow of the last follow (1 -> 0, as iOS);
 *  - the base itself must not be a shrunken copy: if the most follows any list we saw had (or the app shows) is over
 *    10, the result must keep at least half of it (iOS shouldBlockPublish). This catches a relay that returns an old
 *    or truncated list newer-dated than the real one.
 */
export function wipeGuard({ base, tags, target, follow, seen = [], appCount = 0 }) {
  if (!base) return "Your follow list wasn't found on your relays, so nothing was changed. Try again when they answer."
  const before = followsOf(base), after = new Set(followsOf({ tags }))
  const lost = before.filter(pk => pk !== target && !after.has(pk))
  if (lost.length) return `This change would drop ${lost.length} other follow${lost.length === 1 ? "" : "s"}, so it wasn't published.`
  const single = !follow && before.includes(target) && after.size === before.length - 1
  if (!after.size && !single) return "This would publish an empty follow list, so it wasn't published."
  const most = Math.max(appCount, ...seen.map(ev => followsOf(ev).length))
  if (most > 10 && after.size < most / 2)
    return `Your newest follow list has ${before.length} follows but you had ${most}. Publishing it would drop most of them, so nothing was changed.`
  return ""
}

/**
 * Follow or unfollow `target`: find the newest list, edit it, guard it, sign it, send it to the write relays, then
 * store it in Haven's outbox. Throws (and publishes nothing) when the guard refuses.
 * -> { event, follows, relays: [{url, ok, message, local}] }
 */
export async function setFollow({ vault, signer, pubkey, target, follow, readRelays, writeRelays, known, appCount = 0, query, publish = (urls, ev) => pool.publish(urls, ev) }) {
  if (!HEX.test(target ?? "")) throw new Error("That isn't a profile that can be followed.")
  if (target === pubkey) throw new Error("You can't follow or unfollow yourself.")
  const { base, seen } = await findLatestList({ vault, pubkey, relays: uniq([...readRelays, ...writeRelays]), known, query })
  const tags = editedTags(base, target, follow)
  const refused = wipeGuard({ base, tags, target, follow, seen, appCount })
  if (refused) throw new Error(refused)
  // Strictly newer than the base, so no relay keeps the old list over this one on a same-second tie.
  const template = { kind: 3, created_at: Math.max(now(), base.created_at + 1), tags, content: base.content ?? "" }
  const event = checkSigned(await signer.signEvent(template), template, pubkey)
  // Network first: the vault keeps it (and the app shows it) only once a relay took it, so a follow that went
  // nowhere is never shown as done (iOS rolls those back).
  const { network, local: own } = publishRelays(writeRelays)
  const urls = [...network, ...own]
  const results = await Promise.allSettled(publish(urls, event))
  const relays = results.map((r, i) => ({ url: urls[i], ok: r.status === "fulfilled", message: r.status === "fulfilled" ? r.value : String(r.reason?.message ?? r.reason), local: i >= network.length }))
  if (!relays.some(r => r.ok && !r.local)) throw new Error(`No relay took it (0 of ${network.length}), so nothing changed. Try again.`)
  const stored = await vault.outbox.event(event)
  if (!stored.ok && !/^duplicate:/.test(stored.message)) throw new Error(`Sent, but Haven refused the follow list: ${stored.message}`)
  return { event, follows: followsOf(event), relays }
}

/** The badge next to someone's name: "mutual", "following", "follows-you" or "". */
export function relation(iFollow, theyFollowMe) {
  return iFollow && theyFollowMe ? "mutual" : iFollow ? "following" : theyFollowMe ? "follows-you" : ""
}
