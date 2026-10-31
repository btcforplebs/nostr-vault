// Note actions, as on the iPhone's note row: like (kind 7), repost (kind 6, or 16 for other kinds), and the tags a reply (NIP-10) or a
// quote (NIP-18 q tag + nevent) carries. Signed by the user's signer, stored in Haven's outbox, sent to the relays
// publishRelays picks. A repost reads as sent only once it is signed and a relay took it; a like shows at once
// ("pending") and is rolled back if signing or every relay fails (FeedActions.react).
import { neventEncode } from "nostr-tools/nip19"
import { pool, publishRelays } from "./pool.js"
import { appendClientTag } from "./client-tag.js"
import { checkSigned } from "./sync.js"
import { repostInner, repostedId, verifiedCopy } from "./thread.js"
import { keepDeletedCopy } from "./recently-deleted.js"
import { sendDelaySeconds, startCountdown } from "./send-delay.js"
import { defaultReaction } from "./reaction-pref.js"

const HEX64 = /^[0-9a-f]{64}$/
const now = () => Math.floor(Date.now() / 1000)

// The app's ctx ({ vault, session, signer, account }), set once the vault is up. A card has only its event.
let actx = null
export const setActionContext = ctx => {
  actx = ctx
  if (ctx?.session?.pubkey && deletionsFor !== ctx.session.pubkey) { deletionsFor = ctx.session.pubkey; loadDeletions(ctx) }
}
export const actionContext = () => actx

/** How an empty or "+" reaction reads (reactionDisplayEmoji). A one-tap like sends the user's Default Reaction
 *  (net/reaction-pref.js), ❤️ unless they picked another. */
export const REACTION = "❤️"

/** An event's address ("kind:pubkey:d"), or null (NIP10Thread.coordinate): addressable kinds by their d tag, replaceable
 *  ones (0, 3, 10000-19999) with an empty d. Likes, zaps and reposts carry it, so clients counting by address see them. */
export function addressOf(ev) {
  const k = ev?.kind
  if (k >= 30000 && k < 40000) {
    const d = ev.tags?.find(t => t[0] === "d")?.[1]
    return d === undefined ? null : `${k}:${ev.pubkey}:${d}`
  }
  return k === 0 || k === 3 || (k >= 10000 && k < 20000) ? `${k}:${ev.pubkey}:` : null
}

/** NIP-25 reaction to `note`, tagged as the iPhone tags it (FeedActions.react; an article's a tag as
 *  ArticleEngagement.reactionTags). */
export function reactionTemplate(note, content = REACTION) {
  const a = addressOf(note)
  return { kind: 7, created_at: now(), tags: [["e", note.id, ""], ...(a ? [["a", a, ""]] : []), ["p", note.pubkey], ["k", String(note.kind)]], content }
}

/** NIP-18 repost, the reposted event as the content. Kind 6 is only for kind 1 notes; anything else (an article, a
 *  poll, a picture, a comment) is a kind 16 generic repost with a k tag naming its kind (PendingPostManager), plus the
 *  a tag NIP-18 asks for when it is addressable. */
export function repostTemplate(note) {
  if (note.kind === 1) return { kind: 6, created_at: now(), tags: [["e", note.id, ""], ["p", note.pubkey]], content: JSON.stringify(note) }
  const tags = [["e", note.id, ""], ["p", note.pubkey], ["k", String(note.kind)]]
  const a = note.kind >= 30000 && note.kind < 40000 ? addressOf(note) : null
  if (a) tags.push(["a", a])
  return { kind: 16, created_at: now(), tags, content: JSON.stringify(note) }
}

/**
 * NIP-10 tags for a reply to `parent`, as the iPhone's compose builds them (ComposeView+Posting): a parent that is
 * a root gets one "root" e tag; a parent that is a reply gets the thread's root plus a "reply" e tag for itself.
 * Then the parent's author and everyone it tagged, once each.
 */
export function replyTags(parent) {
  const es = (parent.tags ?? []).filter(t => t[0] === "e" && HEX64.test(t[1] ?? "") && t[3] !== "mention")
  const tags = []
  if (!es.length) tags.push(["e", parent.id, "", "root", parent.pubkey])
  else {
    const root = es.find(t => t[3] === "root") ?? es[0]
    tags.push(HEX64.test(root[4] ?? "") ? ["e", root[1], "", "root", root[4]] : ["e", root[1], "", "root"])
    tags.push(["e", parent.id, "", "reply", parent.pubkey])
  }
  const seen = new Set()
  for (const pk of [parent.pubkey, ...(parent.tags ?? []).filter(t => t[0] === "p").map(t => t[1])])
    if (HEX64.test(pk ?? "") && !seen.has(pk)) { seen.add(pk); tags.push(["p", pk]) }
  return tags
}

/** A quote: the nevent line appended to the text, a q tag, and the quoted author tagged. -> { content, tags } */
export function quoteOf(quoted, text) {
  return {
    content: `${text}\nnostr:${neventEncode({ id: quoted.id, author: quoted.pubkey, kind: quoted.kind })}`,
    tags: [["q", quoted.id, "", quoted.pubkey], ["p", quoted.pubkey]],
  }
}

/** The note a card's actions act on: a kind 1, or the note inside a kind 6, signature checked. -> event or null */
export function actionTarget(event) {
  if (event?.kind === 1) return event
  if (event?.kind !== 6) return null
  const inner = repostInner(event)
  return inner?.kind === 1 ? inner : null
}

/**
 * Sign `unsigned` (a note or comment gets the client tag, client-tag.js), send it to the relays publishRelays picks, and
 * once one took it, keep it in Haven's outbox.
 * Done at the first network relay's OK, as the iPhone fills the heart at once: waiting for every relay held it to the
 * slowest one's timeout (5 s). The rest finish in the background; `settled` has every relay's answer.
 * -> { event, relay: url, settled: Promise<[{ url, ok, message }]> }; throws when signing fails or no relay took it.
 */
export async function publishAction(ctx, unsigned) {
  const template = { ...unsigned, tags: appendClientTag(unsigned.tags, unsigned.kind) }
  const event = checkSigned(await ctx.signer.signEvent(template), template, ctx.session.pubkey)
  const { network, local } = publishRelays(ctx.account.relays.write)
  const urls = [...network, ...local]
  const sends = pool.publish(urls, event)
  const settled = Promise.allSettled(sends).then(results =>
    results.map((r, i) => ({ url: urls[i], ok: r.status === "fulfilled", message: r.status === "fulfilled" ? r.value : String(r.reason?.message ?? r.reason) })))
  const first = await firstTaken(sends.slice(0, network.length))
  if (first < 0) throw new Error(`No relay took it (0 of ${network.length})`)
  // Kept in Haven only once it went out: this copy is what shows it as sent after a reload.
  await ctx.vault.outbox.event(event).catch(() => {})
  return { event, relay: urls[first], settled }
}

/** The index of the first of these sends to succeed, or -1 once every one has failed (or there are none). */
export function firstTaken(sends) {
  return new Promise(resolve => {
    let left = sends.length
    if (!left) return resolve(-1)
    sends.forEach((p, i) => p.then(() => resolve(i), () => { if (--left === 0) resolve(-1) }))
  })
}

/** NIP-09 deletion request for one of the account's events. A reaction carries ["k", "7"], as the iPhone's retract;
 *  a post carries only its e tag (NoteDeletion.requestTags). */
export const deletionTemplate = (id, kind) =>
  ({ kind: 5, created_at: now(), tags: kind === 7 ? [["e", id], ["k", "7"]] : [["e", id]], content: "" })

// Ids this account asked to delete: its posts (hidden wherever a card would draw them) and its retracted likes
// (no longer read as sent). Read once per account from the kind 5s kept in Haven's outbox, then kept up to date here.
const deleted = new Set()
let deletionsFor = null
export const isDeleted = id => deleted.has(id)
/** The ids whose deletion hides a card for `event`: its own, and for a repost the note inside it too. */
export function gateIds(event) {
  if (event?.kind !== 6 && event?.kind !== 16) return [event.id]
  let inner
  try { inner = JSON.parse(event.content) } catch {}
  return [...new Set([event.id, typeof inner?.id === "string" ? inner.id : null, repostedId(event)].filter(Boolean))]
}
function markDeleted(ids) {
  for (const id of ids) deleted.add(id)
  for (const id of ids) for (const f of listeners) f(id)
}
export async function loadDeletions(ctx) {
  const mine = await ctx.vault.outbox.query({ kinds: [5], authors: [ctx.session.pubkey], limit: 1000 }).catch(() => [])
  markDeleted(mine.flatMap(ev => (ev.tags ?? []).filter(t => t[0] === "e" && HEX64.test(t[1] ?? "")).map(t => t[1])))
}

// What this account has done to each note: { like, repost } as "busy" | "pending" | "sent" | { error }. "pending" is a
// like shown before a relay took it, or a repost waiting out its send delay. One store, so the same note shown twice (feed and thread) reads the same.
const state = new Map()
const listeners = new Set()
export const actionState = id => state.get(id) ?? {}
export function onActionState(f) { listeners.add(f); return () => listeners.delete(f) }
function put(id, kind, value) {
  state.set(id, { ...actionState(id), [kind]: value })
  for (const f of listeners) f(id)
}

// The emoji this account reacted to each note with, so the button shows it (FeedNoteRow+Reactions).
const emojiOf = new Map()
/** This account's reaction to a note, or null. */
export const reactionOf = id => emojiOf.get(id) ?? null

// The ids of this account's likes on each note, so Unlike knows what to delete.
const likeIds = new Map()
const addLikes = (id, ids) => likeIds.set(id, [...new Set([...(likeIds.get(id) ?? []), ...ids])])

/** Reactions and reposts this account already made, from Haven's outbox: still shown as sent after a reload. A like
 *  it has since taken back (a kind 5 for it) doesn't count. */
export async function loadSent(ctx, id) {
  if (actionState(id).like && actionState(id).repost) return
  const mine = await ctx.vault.outbox.query({ kinds: [6, 7, 16], authors: [ctx.session.pubkey], "#e": [id], limit: 20 }).catch(() => [])
  const likes = mine.filter(ev => ev.kind === 7).map(ev => ev.id)
  const gone = likes.length
    ? new Set((await ctx.vault.outbox.query({ kinds: [5], authors: [ctx.session.pubkey], "#e": likes, limit: 50 }).catch(() => []))
      .flatMap(ev => ev.tags.filter(t => t[0] === "e").map(t => t[1])))
    : new Set()
  for (const ev of mine) {
    if (ev.kind === 7 && (gone.has(ev.id) || deleted.has(ev.id))) continue
    const kind = ev.kind === 7 ? "like" : "repost"
    if (kind === "like") { addLikes(id, [ev.id]); if (!emojiOf.has(id)) emojiOf.set(id, ev.content || REACTION) }
    if (actionState(id)[kind] === undefined) put(id, kind, "sent")
  }
}

/** Like or repost `note` once. A second tap on a sent repost does nothing; on a sent like it is Unlike. `emoji`
 *  (the tapback or the picker) reacts with that emoji: the same one again takes the reaction back, another one
 *  swaps it, the old kind 7 deleted before the new one is signed (FeedActions.react). */
export async function act(ctx, kind, note, emoji) {
  const cur = actionState(note.id)[kind]
  if (cur === "busy" || cur === "pending") return
  // A failed Unlike says so on the heart ({ error, unlike }); a tap on it tries the rest again.
  if (kind === "like" && (cur === "sent" || cur?.unlike)) {
    if (!emoji || cur?.unlike || emoji === emojiOf.get(note.id)) return unlike(ctx, note).catch(() => {})
    try { await unlike(ctx, note) } catch { return }
  } else if (cur === "sent") return
  if (kind === "like") return like(ctx, note, emoji ?? defaultReaction()) // a plain tap: Settings › Default Reaction
  put(note.id, kind, "busy")
  try {
    await publishAction(ctx, repostTemplate(note))
    put(note.id, kind, "sent")
  } catch (e) {
    put(note.id, kind, { error: String(e?.message ?? e) })
  }
}

/**
 * A repost after the send delay, as the iPhone's PendingPostManager.startRepost: nothing is signed until the countdown
 * ends, and cancel() before then leaves nothing signed or sent. While it counts down the repost reads "pending" (a
 * second tap does nothing). `seconds` 0 (Off) sends at once. `onTick(remaining)` drives the countdown pill.
 * -> { cancel(): true if it stopped one still counting, done: Promise<"sent" | "failed" | "undone" | "skipped"> }
 */
export function repostAfterDelay(ctx, note, { seconds = sendDelaySeconds(), onTick = () => {}, countdown = startCountdown } = {}) {
  const cur = actionState(note.id).repost
  if (cur === "busy" || cur === "pending" || cur === "sent") return { cancel: () => false, done: Promise.resolve("skipped") }
  put(note.id, "repost", "pending")
  let settle
  const done = new Promise(r => { settle = r })
  const timer = countdown({
    seconds, onTick,
    onDone: () => {
      put(note.id, "repost", undefined)
      act(ctx, "repost", note).then(() => settle(actionState(note.id).repost === "sent" ? "sent" : "failed"))
    },
  })
  return { cancel: () => { if (!timer.cancel()) return false; put(note.id, "repost", cur); settle("undone"); return true }, done }
}

/** A like shows at once, filled heart or emoji and counted, as on the iPhone (FeedActions.react); signing and the
 *  relays come after. If either fails it is taken off again and the heart says why. */
async function like(ctx, note, emoji) {
  emojiOf.set(note.id, emoji)
  put(note.id, "like", "pending")
  try {
    const { event } = await publishAction(ctx, reactionTemplate(note, emoji))
    addLikes(note.id, [event.id])
    put(note.id, "like", "sent")
  } catch (e) {
    emojiOf.delete(note.id)
    put(note.id, "like", { error: String(e?.message ?? e) })
  }
}

/** This account's reaction as the counts should show it: { emoji } once liked here (also while it is going out),
 *  { emoji: null } once taken back or failed here, null when this session hasn't changed it (the relays' answer
 *  stands). */
export function myReaction(id) {
  const st = actionState(id)
  if (!("like" in st)) return null
  const like = st.like
  if (like === "pending" || like === "sent") return { emoji: emojiOf.get(id) ?? REACTION }
  if (like === undefined || (like?.error && !like.unlike)) return { emoji: null }
  return null
}

/**
 * Take a like back (FeedActions.removeReaction): a kind 5 for each of this account's reactions to the note. A like
 * this browser didn't see made (an older app, another device) is looked up on the account's relays first, as the
 * iPhone's retractUnknown does. Each deletion counts as it goes out, so a retry after a failure sends only the rest.
 * A failure reads as { error, unlike } on the heart, not as liked again.
 */
export async function unlike(ctx, note) {
  put(note.id, "like", "busy")
  try {
    let ids = likeIds.get(note.id) ?? []
    if (!ids.length) {
      const relays = [...new Set([...ctx.account.relays.read, ...ctx.account.relays.write])]
      const found = await pool.querySync(relays, { kinds: [7], authors: [ctx.session.pubkey], "#e": [note.id] }, { maxWait: 6000 })
      ids = found.filter(ev => ev.pubkey === ctx.session.pubkey && !deleted.has(ev.id)).map(ev => ev.id)
      if (ids.length) addLikes(note.id, ids)
    }
    if (!ids.length) throw new Error("Your like wasn't found on your relays")
    for (const id of ids) {
      await publishAction(ctx, deletionTemplate(id, 7))
      likeIds.set(note.id, (likeIds.get(note.id) ?? []).filter(x => x !== id))
      markDeleted([id])
    }
    likeIds.delete(note.id)
    emojiOf.delete(note.id)
    put(note.id, "like", undefined)
  } catch (e) {
    put(note.id, "like", { error: String(e?.message ?? e), unlike: true })
    throw e
  }
}

/** Ask relays to delete one of this account's own posts (NostrService.deleteNote). Hidden here at once. */
export async function deleteNote(ctx, note) {
  if (note.pubkey !== ctx.session.pubkey) throw new Error("Only your own posts can be deleted")
  await publishAction(ctx, deletionTemplate(note.id, note.kind))
  await keepDeletedCopy(ctx, note).catch(() => {}) // Recently Deleted: Haven drops the post once the kind 5 lands
  markDeleted([note.id])
}

/** Where Share and Copy link point, as on the iPhone (FeedNoteRow+Menus): a public page anyone can open. */
export const shareLink = note => `https://nostrvault.app/thread/${neventEncode({ id: note.id, author: note.pubkey, kind: note.kind })}`

// Reply and quote hand the note to Compose through here, so Compose needn't fetch what the card already had.
const handed = new Map()
export function compose(mode, note) {
  handed.set(note.id, note)
  location.hash = `#/compose?${mode}=${note.id}`
}

/** "#/compose?reply=<id>" -> { mode: "reply", id }; anything else -> null */
export function composeTarget(hash = location.hash) {
  const m = /^#\/?compose\?(reply|quote)=([0-9a-f]{64})$/.exec(hash)
  return m ? { mode: m[1], id: m[2] } : null
}

/** The note Compose replies to or quotes: as the card handed it, else from Haven, else the network. */
export async function findNote(ctx, id) {
  if (handed.has(id)) return handed.get(id)
  for (const store of [ctx.vault.feed, ctx.vault.outbox]) {
    const [ev] = await store.query({ ids: [id] }).catch(() => [])
    if (ev) return verifiedCopy(ev)
  }
  const relays = [...ctx.account.relays.read, ...ctx.account.relays.write]
  const [ev] = await pool.querySync([...new Set(relays)], { ids: [id] }, { maxWait: 6000 })
  return ev ? verifiedCopy(ev) : null
}
