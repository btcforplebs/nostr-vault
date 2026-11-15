// The Reader pane's side of the bus (plan P4): what the Reader napplet may ask the shell for, and how the shell opens a
// note or a profile in it. Pure apart from the callbacks, so node tests drive it with a fake bus participant.
//   napplet:compose/new, napplet:compose/reply { event }  -> the Compose napplet (openCompose mounts it in a sheet)
//   napplet:compose/quote { event }                       -> Compose, quoting it (net/actions.js quoteOf's format)
//                                                            With `fullCompose` (the desktop, plan step 2b) the three
//                                                            are shell-answered instead: the site's own full composer
//                                                            (mentions, emoji, photos with ALT, preview, the other kinds)
//                                                            opens; a reply or quote needs a signed event.
//   napplet:link/open { url }                             -> a new tab, http(s) only, no opener, no referrer
//   napplet:link/preview { url }                          -> { data: { title, description, siteName, image } | null }:
//                                                            the page's OpenGraph, read by the shell as the classic
//                                                            link card does (link-preview.js: public https only, CORS,
//                                                            no cookies, no referrer). Reader only: the napplet itself
//                                                            has no network, and no other napplet gets a fetcher.
//   napplet:media/view { event, url }                     -> the shell's full-screen viewer over the note's own media
//                                                            (media-view.js), opened at the tapped picture
//   napplet:note/card { event }                           -> { data }: an article, highlight or poll card's strings,
//                                                            worked out by the shell from the signed event
//                                                            (kind-cards.js); a poll's with its vote count
//   napplet:poll/vote { event, picks }                    -> the classic vote (poll-votes.js sendVote: your signer,
//                                                            your write relays and the poll's own), { data } = the card
//   napplet:note/stats { event }                          -> { data }: your Like and the note's zap total (note-stats.js);
//                                                            changes come after as inc nv.note.stats
//   napplet:note/like { event, emoji? }                   -> the classic Like (likeWithFeedback: react, swap, or take it
//                                                            back), signed by your signer; the result comes as stats
//   napplet:thread/outside { id }                         -> { data: { count } }: replies to that thread from outside
//                                                            your web, which no napplet is shown (outside-count.js)
//   napplet:web/people {}                                 -> { data: { people } }: up to 500 of your web (you, your
//                                                            follows, theirs), sorted, as the classic Global names them
//                                                            in its first filter; built from public follow lists
//   napplet:profile/show { pubkey }                       -> the full classic profile (#/profile/<pk>), Reader kept
//   napplet:article/open { event }                        -> the classic article reader over the Reader
//   napplet:note/repost|zap|menu { event }                -> the classic flows, run by the shell (gap run, after P8):
//                                                            repost with the Send Delay's Undo, the zap picker, the
//                                                            ⋯ menu (copy, bookmark, block, report, delete). The
//                                                            event must carry a valid signature: a napplet can't make
//                                                            the shell repost, zap or delete a note it made up.
//   Reader -> shell inc: nv.key { key, … } (the desktop's keys), nv.hover { pubkey, rect } | { out } (its hover card);
//                    shell -> Reader inc nv.key.cmd { cmd } for j/k/Enter/r/l/z on the Reader's rows (napplet-keys.js)
//   shell -> Reader: napplet:note/open { id }, napplet:profile/open { pubkey }, napplet:feed/open { tag? } (a #tag
//                    link, #/feed?tag=<t>, opens that tag's notes in the Reader)
export const COMPOSE_DONE = "nv.compose.done"
/** A sent note, to the Reader (the Compose napplet emits it; the shell does for the full composer). */
export const COMPOSE_SENT = "nv.compose.sent"
/** Compose posted and the Send Delay counts down (hide the sheet so the pill's Undo can be reached), or it was undone
 *  (show it again, text intact). */
export const COMPOSE_WAITING = "nv.compose.waiting", COMPOSE_UNDONE = "nv.compose.undone"
import { READER_DTAG as READER } from "./first-party-list.js"
import { mediaViewOf } from "./media-view.js"
import { CARD_KINDS } from "./kind-cards.js"
import { askedEmoji } from "./note-stats.js"
import { KEY_TOPIC, HOVER_TOPIC, CTX_TOPIC } from "./napplet-keys.js"
const HEX = /^[0-9a-f]{64}$/

/** A link a napplet asked to open -> the URL to open, or null. http(s) only, no user:pass, at most 2048 characters. */
export function linkTarget(raw) {
  if (typeof raw !== "string" || raw.length > 2048) return null
  let u
  try { u = new URL(raw) } catch { return null }
  if ((u.protocol !== "https:" && u.protocol !== "http:") || u.username || u.password) return null
  return u.href
}

/** The tag a #tag link asks for ("#/feed?tag=Bitcoin" -> "bitcoin"), or "": lower-cased, no #, one word, as the
 *  classic feed's normalizeTag (net/feeds.js, not imported: it pulls the relay pool in). */
export function feedTagOf(hash = "") {
  const i = String(hash).indexOf("?")
  const t = String(new URLSearchParams(i < 0 ? "" : hash.slice(i + 1)).get("tag") ?? "").trim().replace(/^#+/, "").toLowerCase()
  return t && !/\s/.test(t) && [...t].length <= 64 ? t : ""
}

/** Where a route opens the Reader: { archetype, action, payload } for #/thread/<id>, someone's #/profile/<pk>, or a
 *  #/feed?tag=<t> link. */
export function readerOpenFor(route, arg, hash = globalThis.location?.hash ?? "") {
  const tag = route === "feed" ? feedTagOf(hash) : ""
  if (tag) return { archetype: "feed", action: "open", payload: { tag } }
  if (route === "thread" && HEX.test(arg ?? "")) return { archetype: "note", action: "open", payload: { id: arg } }
  if (route === "profile" && HEX.test(arg ?? "")) return { archetype: "profile", action: "open", payload: { pubkey: arg } }
  return null
}

/**
 * bus: bus.js. openCompose: () => Promise<napplet> (mounts Compose, resolves once it can take a delivery).
 * onComposeDone(): close the sheet. openUrl(url): window.open. -> { me, close }: `me` is the shell's participant.
 */
/** The note a napplet handed over, if its signature checks and it is something the actions act on (kind 1, or the
 *  kind 1 inside a kind 6). -> event | null. `verify`: nostr-tools verifyEvent. */
export function actionNote(raw, verify) {
  // A plain copy is what's checked: nostr-tools caches "verified" on the object under a symbol, and a spread copy of a
  // verified event keeps it, so an edited copy would pass unchecked. JSON keeps only the event's own fields.
  let ev = null
  try { ev = raw && typeof raw === "object" ? JSON.parse(JSON.stringify(raw)) : null } catch {}
  let ok = false
  try { ok = !!ev && verify(ev) } catch {}
  if (!ok) return null
  if (ev.kind === 1) return ev
  if (ev.kind === 6) { try { const inner = JSON.parse(ev.content); return inner?.kind === 1 && verify(inner) ? inner : null } catch { return null } }
  return null
}

/** link/preview's answer: only what the card draws, as plain strings; the picture an https address the Reader then
 *  asks for as bytes (resource.bytes, the shell's picture rules). */
export function previewCard(meta) {
  if (!meta?.title) return null
  const str = v => (typeof v === "string" && v ? v.slice(0, 300) : null)
  return { title: str(meta.title), description: str(meta.description), siteName: str(meta.siteName), image: /^https:\/\//i.test(meta.image ?? "") ? meta.image : null }
}

/** A plain copy of the handed-over event if its signature checks (actionNote's rule, any kind), else null. */
export function signedOf(raw, verify) {
  let ev = null
  try { ev = raw && typeof raw === "object" ? JSON.parse(JSON.stringify(raw)) : null } catch {}
  try { return ev && verify(ev) ? ev : null } catch { return null }
}

/** The note a Like or zap total is for: a signed note, article, highlight or poll the Reader draws (a repost: the
 *  note inside it). -> event | null. */
export function likedNote(raw, verify) {
  const ev = signedOf(raw, verify)
  if (!ev) return null
  if (ev.kind === 1 || CARD_KINDS.includes(ev.kind)) return ev
  return ev.kind === 6 ? actionNote(ev, verify) : null
}

export function readerIntents({ bus, openCompose, fullCompose = null, onComposeDone, onComposeWaiting = () => {}, onComposeUndone = () => {}, openUrl, verify = () => false, onRepost = () => {}, onZap = () => {}, onMenu = () => {}, onMedia = () => {}, preview = async () => null, card = async () => null, vote = async () => null, onArticle = () => {}, onProfile = null, stats = null, like = null, onKey = null, onHover = null, onCtx = null, beside = null, outside = null, webPeople = null }) {
  const on = { [COMPOSE_DONE]: onComposeDone, [COMPOSE_WAITING]: onComposeWaiting, [COMPOSE_UNDONE]: onComposeUndone,
    ...(onKey ? { [KEY_TOPIC]: onKey } : {}), ...(onHover ? { [HOVER_TOPIC]: onHover } : {}), ...(onCtx ? { [CTX_TOPIC]: onCtx } : {}) }
  const me = { dTag: "shell", send: m => { if (m?.type === "inc.event" && on[m.topic]) on[m.topic](m.payload) } }
  for (const t of Object.keys(on)) bus.subscribe(me, t)
  const off = [
    ...(fullCompose ? [
      bus.register({ id: "shell-compose-new", title: "Compose", archetype: "compose", actions: ["new"], conventions: [], deliver: () => { fullCompose("new", null); return { ok: true } } }),
      ...["reply", "quote"].map(action => bus.register({ id: `shell-compose-${action}`, title: "Compose", archetype: "compose", actions: [action], conventions: [], deliver: p => {
        const ev = signedOf(p?.event, verify)
        if (!ev) return { ok: false, error: "not a signed note" }
        fullCompose(action, ev)
        return { ok: true }
      } })),
    ] : [bus.register({ id: "nv-compose", title: "Compose", archetype: "compose", actions: ["new", "reply", "quote"], conventions: [], open: openCompose })]),
    ...[["repost", onRepost], ["zap", onZap], ["menu", onMenu]].map(([action, run]) => bus.register({ id: `shell-note-${action}`, title: action, archetype: "note", actions: [action], conventions: [], deliver: p => {
      const note = actionNote(p?.event, verify)
      if (!note) return { ok: false, error: "not a signed note" }
      run(note)
      return { ok: true }
    } })),
    bus.register({ id: "shell-note-card", title: "Card", archetype: "note", actions: ["card"], conventions: [], deliver: async (p, from) => {
      if (from?.dTag !== READER) return { ok: false, error: "the Reader's only" }
      const ev = signedOf(p?.event, verify)
      if (!ev || !CARD_KINDS.includes(ev.kind)) return { ok: false, error: "not a signed article, highlight or poll" }
      return { ok: true, data: await card(ev) }
    } }),
    bus.register({ id: "shell-poll-vote", title: "Vote", archetype: "poll", actions: ["vote"], conventions: [], deliver: async (p, from) => {
      if (from?.dTag !== READER) return { ok: false, error: "the Reader's only" }
      const ev = signedOf(p?.event, verify)
      const picks = Array.isArray(p?.picks) ? p.picks.filter(x => typeof x === "string").slice(0, 32) : []
      if (ev?.kind !== 1068 || !picks.length) return { ok: false, error: "not a signed poll with a pick" }
      try { return { ok: true, data: await vote(ev, picks) } } catch (e) { return { ok: false, error: String(e?.message ?? e) } }
    } }),
    // A note's thread beside the list (desktop, plan step 2): the shell opens it; refused, the Reader opens it in place.
    ...(beside ? [bus.register({ id: "shell-note-beside", title: "Beside", archetype: "note", actions: ["beside"], conventions: [], deliver: (p, from) => {
      if (from?.dTag !== READER) return { ok: false, error: "the Reader's only" }
      if (!HEX.test(p?.id ?? "")) return { ok: false, error: "not a note id" }
      return beside(p.id) ? { ok: true } : { ok: false, error: "no room beside the list" }
    } })] : []),
    ...(onProfile ? [bus.register({ id: "shell-profile-show", title: "Profile", archetype: "profile", actions: ["show"], conventions: [], deliver: p => {
      if (!HEX.test(p?.pubkey ?? "")) return { ok: false, error: "not a pubkey" }
      onProfile(p.pubkey)
      return { ok: true }
    } })] : []),
    ...(stats ? [bus.register({ id: "shell-note-stats", title: "Stats", archetype: "note", actions: ["stats"], conventions: [], deliver: (p, from) => {
      if (from?.dTag !== READER) return { ok: false, error: "the Reader's only" }
      const note = likedNote(p?.event, verify)
      if (!note) return { ok: false, error: "not a signed note" }
      return { ok: true, data: stats(note) }
    } })] : []),
    ...(like ? [bus.register({ id: "shell-note-like", title: "Like", archetype: "note", actions: ["like"], conventions: [], deliver: (p, from) => {
      if (from?.dTag !== READER) return { ok: false, error: "the Reader's only" }
      const note = likedNote(p?.event, verify)
      if (!note) return { ok: false, error: "not a signed note" }
      const why = like(note, askedEmoji(p?.emoji))
      return why ? { ok: false, error: why } : { ok: true }
    } })] : []),
    ...(outside ? [bus.register({ id: "shell-thread-outside", title: "Outside", archetype: "thread", actions: ["outside"], conventions: [], deliver: async (p, from) => {
      if (from?.dTag !== READER) return { ok: false, error: "the Reader's only" }
      if (!HEX.test(p?.id ?? "")) return { ok: false, error: "not a note id" }
      const count = await outside(p.id).catch(() => 0)
      return { ok: true, data: { count: Number.isInteger(count) && count > 0 ? count : 0 } }
    } })] : []),
    ...(webPeople ? [bus.register({ id: "shell-web-people", title: "Your web", archetype: "web", actions: ["people"], conventions: [], deliver: async (p, from) => {
      if (from?.dTag !== READER) return { ok: false, error: "the Reader's only" }
      const people = await webPeople().catch(() => null)
      return { ok: true, data: { people: Array.isArray(people) ? people.filter(pk => HEX.test(pk ?? "")).slice(0, 500) : [] } }
    } })] : []),
    bus.register({ id: "shell-article-open", title: "Read", archetype: "article", actions: ["open"], conventions: [], deliver: p => {
      const ev = signedOf(p?.event, verify)
      if (ev?.kind !== 30023) return { ok: false, error: "not a signed article" }
      onArticle(ev)
      return { ok: true }
    } }),
    bus.register({ id: "shell-media-view", title: "View", archetype: "media", actions: ["view"], conventions: [], deliver: p => {
      const note = actionNote(p?.event, verify)
      const view = note && mediaViewOf(note, p?.url)
      if (!view) return { ok: false, error: note ? "not a picture in this note" : "not a signed note" }
      onMedia({ ...view, author: note.pubkey })
      return { ok: true }
    } }),
    bus.register({ id: "shell-link", title: "Open link", archetype: "link", actions: ["open"], conventions: [], deliver: p => {
      const url = linkTarget(p?.url)
      if (!url) return { ok: false, error: "not an http(s) link" }
      openUrl(url)
      return { ok: true }
    } }),
    bus.register({ id: "shell-link-preview", title: "Link preview", archetype: "link", actions: ["preview"], conventions: [], deliver: async (p, from) => {
      if (from?.dTag !== READER) return { ok: false, error: "the Reader's only" }
      const url = linkTarget(p?.url)
      if (!url) return { ok: false, error: "not an http(s) link" }
      let meta = null
      try { meta = await preview(url) } catch {}
      return { ok: true, data: previewCard(meta) }
    } }),
  ]
  return { me, close: () => { bus.forget(me); off.forEach(f => f()) } }
}
