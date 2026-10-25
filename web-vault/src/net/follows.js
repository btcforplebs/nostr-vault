// Follow / Unfollow: a new kind 3 built on the newest one this browser can find, with the iPhone app's wipe guard
// (ContactManager.mayPublish). A kind 3 replaces the whole list, so a stale or missing base would wipe the follows:
// nothing is published unless a list came from one of the user's relays or most of them answered, and never one that
// drops most of what the user had. An account that never had a list may start one once most of its relays answered.
import { verifyEvent } from "nostr-tools/pure"
import { pool, publishRelays, PROFILE_RELAYS, uniq } from "./pool.js"
import { checkSigned } from "./sync.js"

const HEX = /^[0-9a-f]{64}$/
const now = () => Math.floor(Date.now() / 1000)
/** How far ahead of this clock a kind 3 may be dated and still count. A list dated later is ignored, and a new list
 *  is never dated later than this, so one bad clock can't pin the follow list in the future for every other app. */
export const MAX_SKEW = 15 * 60
/** How old this browser's own copy may be and still be built on when none of the user's relays had a list. */
export const MAX_LOCAL_AGE = 7 * 86400
const ASK_MS = 6000

/** verifyEvent on a fresh copy: it trusts a "verified" flag an event object carries, and a relay or a test can set one. */
const verifiedCopy = ({ id, pubkey, created_at, kind, tags, content, sig }) => verifyEvent({ id, pubkey, created_at, kind, tags, content, sig })

/** The followed pubkeys in a kind 3, in order, once each. */
export const followsOf = ev => uniq((ev?.tags ?? []).filter(t => t[0] === "p" && HEX.test(t[1] ?? "")).map(t => t[1]))

/** The newest of these kind 3s by this author (ties: the lower id, as NIP-01 replaceable events). Lists dated
 *  MAX_SKEW or more ahead of now are skipped. */
export function newestList(lists, pubkey, at = now()) {
  let best
  for (const ev of lists) {
    if (ev?.kind !== 3 || ev.pubkey !== pubkey || ev.created_at >= at + MAX_SKEW) continue
    if (!best || ev.created_at > best.created_at || (ev.created_at === best.created_at && ev.id < best.id)) best = ev
  }
  return best
}

/**
 * One relay's answer to `filter`: { events, answered }. `answered` is true only on the relay's own EOSE. pool.querySync
 * can't be used here: it turns an unreachable relay, and a relay that times out, into the same empty answer as
 * "no list" (nostr-tools counts its EOSE timeout as an EOSE), and that is the difference the guard needs.
 */
export async function askRelay(url, filter, ms = ASK_MS) {
  let relay
  try { relay = await pool.ensureRelay(url, { connectionTimeout: ms }) } catch { return { events: [], answered: false } }
  return new Promise(resolve => {
    const events = []
    let sub = null, finished = false
    const done = answered => {
      if (finished) return
      finished = true
      clearTimeout(timer)
      try { sub?.close() } catch {}
      resolve({ events, answered })
    }
    const timer = setTimeout(() => done(false), ms)
    try {
      // Its own timeout far past ours, so only a real EOSE calls oneose before our timer does.
      sub = relay.subscribe([filter], { eoseTimeout: ms * 10, onevent: ev => events.push(ev), oneose: () => done(true) })
    } catch { done(false) }
  })
}

/**
 * The newest kind 3 of `pubkey` from the vault (Haven's outbox), the network and `known` (the list the app holds).
 * `asked`: how many of `relays` (the user's own) were asked; `answered`: how many of those sent their EOSE (purplepag.es
 * is asked too but doesn't count for either). `netFound`: a kind 3 came from one of the user's own relays (a copy from
 * purplepag.es alone may be old; it is still in `seen`, so it can be the base and counts toward the size rule).
 * Nothing found here is written to the vault: a list the guard refuses must not become the app's follows.
 * `ahead`: a list of the user's was found but dated too far ahead to count, so a list exists somewhere.
 * `ask` is for tests. -> { base, seen: [kind 3], asked, answered, netFound, ahead }
 */
export async function findLatestList({ vault, pubkey, relays, known, ask = askRelay }) {
  const filter = { kinds: [3], authors: [pubkey] }
  const own = uniq(relays)
  const asked = uniq([...own, ...PROFILE_RELAYS])
  const [local, replies] = await Promise.all([
    vault.outbox.query(filter).catch(() => []),
    Promise.all(asked.map(url => ask(url, filter).catch(() => ({ events: [], answered: false })))),
  ])
  const net = replies.flatMap(r => r.events).filter(ev => ev?.kind === 3 && ev.pubkey === pubkey && verifiedCopy(ev))
  const answered = replies.filter((r, i) => r.answered && own.includes(asked[i])).length
  const at = now()
  const mine = [...local, ...net, ...(known ? [known] : [])].filter(ev => ev?.kind === 3 && ev.pubkey === pubkey)
  const seen = mine.filter(ev => ev.created_at < at + MAX_SKEW)
  const netFound = replies.some((r, i) => own.includes(asked[i]) &&
    r.events.some(ev => ev?.kind === 3 && ev.pubkey === pubkey && verifiedCopy(ev) && ev.created_at < at + MAX_SKEW))
  return { base: newestList(seen, pubkey, at), seen, asked: own.length, answered, netFound, ahead: mine.length > seen.length }
}

/** The tags of `base` with `target` followed or not. Every other tag, and the content, are kept as they were. */
export function editedTags(base, target, follow) {
  const tags = (base?.tags ?? []).filter(t => !(t[0] === "p" && t[1] === target))
  if (follow) tags.push(["p", target])
  return tags
}

/**
 * Why this list may not be published, or "" if it may. The rules, in order:
 *  - no list came from the user's own relays and no more than half of them answered: refuse. Then the base can only be
 *    this browser's own copy, which may be old, and a relay that timed out may hold the real list; the size rule
 *    below can't tell (the app's count comes from that same copy). iOS (loadConfirmsList) wants every relay; the web
 *    takes a majority (Logen, 2026-10-14) so one relay that is down for good doesn't block following.
 *  - no base list found: a first list of one follow, only once every one of the user's relays answered without one,
 *    as iOS (loadConfirmsList with foundList false). Here the majority isn't enough: with no base the size rule can't
 *    protect a real list sitting on the relay that didn't answer. Refused for an unfollow, when the app shows follows,
 *    and when a list was found dated ahead (`ahead`): those mean a list exists somewhere;
 *  - nothing that would be empty, unless it is a single unfollow of the last follow (1 -> 0, as iOS);
 *  - the base itself must not be a shrunken copy: if the most follows any list we saw had (or the app shows) is over
 *    10, the result must keep at least half of it (iOS shouldBlockPublish). This catches a relay that returns an old
 *    or truncated list newer-dated than the real one.
 *  - no list came from the user's relays and the base (then this browser's copy) is over MAX_LOCAL_AGE old: refuse.
 *    The size rule can't catch that case (the base and the app's count are the same copy), and an old copy would drop
 *    every follow since and bring back anyone unfollowed on another client.
 */
export function wipeGuard({ base, tags, target, follow, seen = [], appCount = 0, asked = 0, answered = 0, netFound = false, ahead = false, at = now() }) {
  if (!netFound && !(asked > 0 && answered * 2 > asked)) {
    if (!answered) return "None of your relays answered, so your newest follow list isn't known and nothing was changed. Try again when they're reachable."
    return `Only ${answered} of your ${asked} relays answered and none had your follow list, so your newest one isn't known and nothing was changed. Try again when most of them are reachable.`
  }
  if (!base && (!follow || appCount > 0 || ahead))
    return "Your follow list wasn't found on your relays, so nothing was changed. Try again when they answer."
  if (!base && answered < asked)
    return `${answered} of your ${asked} relays answered and none had a follow list. Your first one needs every relay to answer, so nothing was changed. Try again shortly.`
  if (base && !netFound && base.created_at < at - MAX_LOCAL_AGE) {
    const day = new Date(base.created_at * 1000).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" })
    return `Your relays no longer have your follow list and this browser's copy is from ${day}, so nothing was changed. Open the app on your phone, or try again when your relays are reachable.`
  }
  const before = followsOf(base), after = new Set(followsOf({ tags }))
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
export async function setFollow({ vault, signer, pubkey, target, follow, readRelays, writeRelays, known, appCount = 0, ask, publish = (urls, ev) => pool.publish(urls, ev) }) {
  if (!HEX.test(target ?? "")) throw new Error("That isn't a profile that can be followed.")
  if (target === pubkey) throw new Error("You can't follow or unfollow yourself.")
  const { base, seen, asked, answered, netFound, ahead } = await findLatestList({ vault, pubkey, relays: uniq([...readRelays, ...writeRelays]), known, ask })
  const tags = editedTags(base, target, follow)
  const refused = wipeGuard({ base, tags, target, follow, seen, appCount, asked, answered, netFound, ahead })
  if (refused) throw new Error(refused)
  // Newer than the base, so no relay keeps the old list over this one on a same-second tie. findLatestList only
  // picks a base dated before now + MAX_SKEW, so this is never later than that.
  const template = { kind: 3, created_at: Math.max(now(), (base?.created_at ?? 0) + 1), tags, content: base?.content ?? "" }
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
