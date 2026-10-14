// Note actions, as on the iPhone's note row: like (kind 7), repost (kind 6), and the tags a reply (NIP-10) or a
// quote (NIP-18 q tag + nevent) carries. Signed by the user's signer, stored in Haven's outbox, sent to the relays
// publishRelays picks. A like or repost reads as sent only once it is signed and a relay took it.
import { neventEncode } from "nostr-tools/nip19"
import { pool, publishRelays } from "./pool.js"
import { checkSigned } from "./sync.js"
import { verifiedCopy } from "./thread.js"

const HEX64 = /^[0-9a-f]{64}$/
const now = () => Math.floor(Date.now() / 1000)

// The app's ctx ({ vault, session, signer, account }), set once the vault is up. A card has only its event.
let actx = null
export const setActionContext = ctx => { actx = ctx }
export const actionContext = () => actx

/** The iPhone app's quick reaction (HavenConfig.defaultReactionEmoji). */
export const REACTION = "❤️"

/** NIP-25 reaction to `note`, tagged as the iPhone tags it (FeedActions.react). */
export const reactionTemplate = (note, content = REACTION) =>
  ({ kind: 7, created_at: now(), tags: [["e", note.id, ""], ["p", note.pubkey], ["k", String(note.kind)]], content })

/** NIP-18 repost: the note itself as the content. */
export const repostTemplate = note =>
  ({ kind: 6, created_at: now(), tags: [["e", note.id, ""], ["p", note.pubkey]], content: JSON.stringify(note) })

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
  let inner
  try { inner = JSON.parse(event.content) } catch { return null }
  return inner?.kind === 1 ? verifiedCopy(inner) : null
}

/**
 * Sign `template`, send it to the relays publishRelays picks, and once one took it, keep it in Haven's outbox.
 * -> { event, relays: [{ url, ok, message }] }; throws when signing fails or no relay took it.
 */
export async function publishAction(ctx, template) {
  const event = checkSigned(await ctx.signer.signEvent(template), template, ctx.session.pubkey)
  const { network, local } = publishRelays(ctx.account.relays.write)
  const urls = [...network, ...local]
  const results = await Promise.allSettled(pool.publish(urls, event))
  const relays = results.map((r, i) => ({ url: urls[i], ok: r.status === "fulfilled", message: r.status === "fulfilled" ? r.value : String(r.reason?.message ?? r.reason) }))
  if (!relays.some((r, i) => r.ok && i < network.length)) throw new Error(`No relay took it (0 of ${network.length})`)
  // Kept in Haven only once it went out: this copy is what shows it as sent after a reload.
  await ctx.vault.outbox.event(event).catch(() => {})
  return { event, relays }
}

// What this account has done to each note: { like, repost } as "busy" | "sent" | { error }. One store, so the same
// note shown twice (feed and thread) reads the same.
const state = new Map()
const listeners = new Set()
export const actionState = id => state.get(id) ?? {}
export function onActionState(f) { listeners.add(f); return () => listeners.delete(f) }
function put(id, kind, value) {
  state.set(id, { ...actionState(id), [kind]: value })
  for (const f of listeners) f(id)
}

/** Reactions and reposts this account already made, from Haven's outbox: still shown as sent after a reload. */
export async function loadSent(ctx, id) {
  if (actionState(id).like && actionState(id).repost) return
  const mine = await ctx.vault.outbox.query({ kinds: [6, 7], authors: [ctx.session.pubkey], "#e": [id], limit: 20 }).catch(() => [])
  for (const ev of mine) {
    const kind = ev.kind === 7 ? "like" : "repost"
    if (actionState(id)[kind] === undefined) put(id, kind, "sent")
  }
}

/** Like or repost `note` once. A second tap on a sent one does nothing: taking it back (NIP-09) isn't here yet. */
export async function act(ctx, kind, note) {
  const cur = actionState(note.id)[kind]
  if (cur === "busy" || cur === "sent") return
  put(note.id, kind, "busy")
  try {
    await publishAction(ctx, kind === "like" ? reactionTemplate(note) : repostTemplate(note))
    put(note.id, kind, "sent")
  } catch (e) {
    put(note.id, kind, { error: String(e?.message ?? e) })
  }
}

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
