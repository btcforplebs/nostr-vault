// Edit Profile, as the iPhone's ProfileEditView saves it: a kind 0 replaces the whole profile, so a save starts
// from the newest one on the relays and changes only the fields the user edited (ProfileMetadataMerge). lud06, bot
// and every key the form doesn't show are kept, and so are the old tags (NIP-39 identities, NIP-30 emoji). If the
// newest copy can't be found and the relays don't all say there is none, nothing is published.
import { verifyEvent } from "nostr-tools/pure"
import { pool, publishRelays, uniq, DEFAULT_RELAYS, PROFILE_RELAYS } from "./pool.js"
import { checkSigned } from "./sync.js"
import { askRelay } from "./follows.js"
import { putProfile } from "./profiles.js"

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
 * The newest kind 0 from Haven and the relays (the account's, the defaults, purplepag.es), as
 * NostrService.lookupNewestReplaceable. -> { event, asked, answered }; `confirmedNone` when every relay answered
 * (EOSE) with none. `ask` is for tests.
 */
export async function latestProfile(ctx, { ask = askRelay } = {}) {
  const me = ctx.session.pubkey
  const filter = { kinds: [0], authors: [me] }
  const relays = uniq([...ctx.account.relays.read, ...ctx.account.relays.write, ...DEFAULT_RELAYS, ...PROFILE_RELAYS])
  const [local, replies] = await Promise.all([
    localProfile(ctx.vault, me),
    Promise.all(relays.map(url => ask(url, filter).catch(() => ({ events: [], answered: false })))),
  ])
  const net = replies.flatMap(r => r.events).filter(ev => ev?.kind === 0 && ev.pubkey === me && verifiedCopy(ev))
  const event = newest([...(local ? [local] : []), ...net], me)
  const answered = replies.filter(r => r.answered).length
  return { event, asked: relays.length, answered, confirmedNone: !event && relays.length > 0 && answered >= relays.length }
}

/**
 * Save the edit: the changed fields merged onto the newest kind 0, signed with its tags, dated after it, sent to
 * the write relays and purplepag.es, kept in Haven's outbox and shown at once. -> { event, relays };
 * throws when the newest copy can't be found, signing fails, or no relay took it. `lookup` and `publish` are for tests.
 */
export async function saveProfile(ctx, initial, edited, { lookup = latestProfile, publish = (urls, ev) => pool.publish(urls, ev) } = {}) {
  const found = await lookup(ctx)
  if (!found.event && !found.confirmedNone) throw new Error("Couldn't load your current profile from the relays. Nothing was changed; try again.")
  const prev = found.event
  const template = {
    kind: 0,
    created_at: Math.max(now(), (prev?.created_at ?? 0) + 1),
    tags: prev?.tags ?? [],
    content: JSON.stringify(merge(parseContent(prev?.content), initial, edited)),
  }
  const event = checkSigned(await ctx.signer.signEvent(template), template, ctx.session.pubkey)
  const urls = uniq([...publishRelays(ctx.account.relays.write).network, ...PROFILE_RELAYS])
  const results = await Promise.allSettled(publish(urls, event))
  const relays = results.map((r, i) => ({ url: urls[i], ok: r.status === "fulfilled", message: r.status === "fulfilled" ? r.value : String(r.reason?.message ?? r.reason) }))
  if (!relays.some(r => r.ok)) throw new Error(`No relay took it (0 of ${urls.length})`)
  await ctx.vault.outbox.event(event).catch(() => {})
  putProfile(event)
  return { event, relays }
}
