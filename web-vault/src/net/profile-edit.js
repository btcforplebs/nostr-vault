// Edit Profile, as the iPhone's ProfileEditView saves it: a kind 0 replaces the whole profile, so a save starts
// from the newest one on the relays and changes only the fields the user edited (ProfileMetadataMerge). lud06, bot
// and every key the form doesn't show are kept, and so are the old tags (NIP-39 identities, NIP-30 emoji). If the
// newest copy isn't known (profileGuard: the follow list's rules), nothing is published.
import { verifyEvent } from "nostr-tools/pure"
import { pool, publishRelays, uniq, DEFAULT_RELAYS, PROFILE_RELAYS } from "./pool.js"
import { checkSigned } from "./sync.js"
import { askRelay, MAX_SKEW, MAX_LOCAL_AGE } from "./follows.js"
import { putProfile } from "./profiles.js"
import { firstTaken } from "./actions.js"

/** The kind-0 keys the form shows, in its order. */
export const FIELDS = ["display_name", "name", "nip05", "about", "picture", "banner", "website", "lud16"]

const now = () => Math.floor(Date.now() / 1000)
const trim = v => (typeof v === "string" ? v.trim() : "")
const verifiedCopy = ({ id, pubkey, created_at, kind, tags, content, sig }) => verifyEvent({ id, pubkey, created_at, kind, tags, content, sig })

/** The JSON object in a kind-0 content; {} when there is none or it isn't an object. */
export function parseContent(content) {
  try {
    const o = JSON.parse(content ?? "")
    return o && typeof o === "object" && !Array.isArray(o) ? o : {}
  } catch { return {} }
}

/** What the form shows for a kind 0: each field as a string, "" when missing or not a string. */
export function formFields(ev) {
  const c = parseContent(ev?.content)
  return Object.fromEntries(FIELDS.map(k => [k, typeof c[k] === "string" ? c[k] : ""]))
}

/** True when a field differs from what the form showed, ignoring the spaces a save trims anyway. */
export const hasChanges = (initial, edited) => FIELDS.some(k => trim(edited[k]) !== trim(initial[k]))

/** `base` with each changed field applied: a changed field overwrites its key, or removes it when cleared. An
 *  unchanged field leaves `base` alone, so a newer value on the relays than the one the form showed isn't reverted. */
export function merge(base, initial, edited) {
  const out = { ...base }
  for (const k of FIELDS) {
    const v = trim(edited[k])
    if (v === trim(initial[k])) continue
    if (v) out[k] = v
    else delete out[k]
  }
  return out
}

const newest = (evs, pubkey) => evs.reduce((a, e) => (e?.kind === 0 && e.pubkey === pubkey && (!a || e.created_at > a.created_at) ? e : a), undefined)

/** The newest kind 0 this browser holds for the account (Haven's outbox, then /feed): what the form opens with. */
export async function localProfile(vault, pubkey) {
  const f = { kinds: [0], authors: [pubkey] }
  const [a, b] = await Promise.all([vault.outbox.query(f).catch(() => []), vault.feed.query(f).catch(() => [])])
  return newest([...a, ...b], pubkey)
}

/**
 * The newest kind 0 from Haven and the relays, as NostrService.lookupNewestReplaceable, with follows.js's rules for
 * what counts: a copy dated MAX_SKEW or more ahead is skipped, and every copy, Haven's too, is signature-checked.
 * `asked` / `answered`: the account's own relays, and how many sent their EOSE (the defaults and purplepag.es are asked
 * too but don't count). `netFound`: a copy came from one of the account's own relays. `fromNet`: the newest copy came
 * from a relay, not only from this browser. `future`: a signed copy was skipped for being dated ahead. `ask` and `at`
 * are for tests.
 * -> { event, asked, answered, netFound, fromNet, future }
 */
export async function latestProfile(ctx, { ask = askRelay, at = now() } = {}) {
  const me = ctx.session.pubkey
  const filter = { kinds: [0], authors: [me] }
  const own = uniq([...ctx.account.relays.read, ...ctx.account.relays.write])
  const relays = uniq([...own, ...DEFAULT_RELAYS, ...PROFILE_RELAYS])
  const mineSigned = ev => ev?.kind === 0 && ev.pubkey === me && verifiedCopy(ev)
  const ok = ev => mineSigned(ev) && ev.created_at < at + MAX_SKEW
  const [local, replies] = await Promise.all([
    localProfile(ctx.vault, me),
    Promise.all(relays.map(url => ask(url, filter).catch(() => ({ events: [], answered: false })))),
  ])
  const net = replies.flatMap(r => r.events).filter(ok)
  const event = newest([...(ok(local) ? [local] : []), ...net], me)
  const mine = i => own.includes(relays[i])
  return {
    event,
    asked: own.length,
    answered: replies.filter((r, i) => r.answered && mine(i)).length,
    netFound: replies.some((r, i) => mine(i) && r.events.some(ok)),
    fromNet: !!event && net.some(ev => ev.id === event.id),
    future: [local, ...replies.flatMap(r => r.events)].some(ev => ev?.created_at >= at + MAX_SKEW && mineSigned(ev)),
  }
}

/**
 * Why a save may not go out, or "" (follows.js wipeGuard). A kind 0 replaces the whole profile, so the base must be
 * known: a copy came from the account's own relays; or, with most of them answering, one from elsewhere (this browser,
 * a default relay, purplepag.es) under MAX_LOCAL_AGE old; or none anywhere (a first profile), only when every one of
 * them answered, as iOS's confirmedNone. A signed copy dated ahead would hide any save, so it always refuses.
 */
export function profileGuard({ event, asked, answered, netFound, future }, at = now()) {
  if (future) return "Your profile on the relays is dated in the future, so a save wouldn't show and nothing was changed."
  if (netFound) return ""
  if (!asked) return "You have no relays set, so your current profile isn't known and nothing was changed. Add your relays first."
  if (!answered) return "None of your relays answered, so your current profile isn't known and nothing was changed. Try again when they're reachable."
  if (!event) {
    if (answered < asked) return `Only ${answered} of your ${asked} relays answered and none had your profile, so your current one isn't known and nothing was changed. Try again when all of them are reachable.`
    return ""
  }
  if (answered * 2 <= asked) return `Only ${answered} of your ${asked} relays answered and none had your profile, so your current one isn't known and nothing was changed. Try again when most of them are reachable.`
  if (event.created_at < at - MAX_LOCAL_AGE) {
    const day = new Date(event.created_at * 1000).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" })
    return `Your relays don't have your profile and the only copy found is from ${day}, so nothing was changed. Try again when your relays have it.`
  }
  return ""
}

/**
 * Save the edit: the changed fields merged onto the newest kind 0, signed with its tags, dated after it, sent to
 * the write relays and purplepag.es, kept in Haven's outbox and shown at once once one relay took it.
 * -> { event, taken: the first relay's URL, settled: Promise<[{ url, ok, message }]> };
 * throws when the newest copy can't be found, signing fails, or no relay took it. `lookup` and `publish` are for tests.
 */
export async function saveProfile(ctx, initial, edited, { lookup = latestProfile, publish = (urls, ev) => pool.publish(urls, ev) } = {}) {
  const found = await lookup(ctx)
  const refused = profileGuard(found)
  if (refused) throw new Error(refused)
  const prev = found.event
  const template = {
    kind: 0,
    created_at: Math.max(now(), (prev?.created_at ?? 0) + 1),
    tags: prev?.tags ?? [],
    content: JSON.stringify(merge(parseContent(prev?.content), initial, edited)),
  }
  const event = checkSigned(await ctx.signer.signEvent(template), template, ctx.session.pubkey)
  const urls = uniq([...publishRelays(ctx.account.relays.write).network, ...PROFILE_RELAYS])
  // Done once one relay took it, not at the slowest relay's answer (a relay that never answers held Save for 5 s);
  // the other sends carry on in the background, and `settled` says how each went.
  const sends = publish(urls, event)
  const settled = Promise.allSettled(sends).then(results => results.map((r, i) => ({ url: urls[i], ok: r.status === "fulfilled", message: r.status === "fulfilled" ? r.value : String(r.reason?.message ?? r.reason) })))
  const first = await firstTaken(sends)
  if (first < 0) throw new Error(`No relay took it (0 of ${urls.length})`)
  await ctx.vault.outbox.event(event).catch(() => {}) // the relays have it; Haven's copy only speeds the next open
  putProfile(event)
  return { event, taken: urls[first], settled }
}
