// The Reader pane's side of the bus (plan P4): what the Reader napplet may ask the shell for, and how the shell opens a
// note or a profile in it. Pure apart from the callbacks, so node tests drive it with a fake bus participant.
//   napplet:compose/new, napplet:compose/reply { event }  -> the Compose napplet (openCompose mounts it in a sheet)
//   napplet:compose/quote { event }                       -> Compose, quoting it (net/actions.js quoteOf's format)
//   napplet:link/open { url }                             -> a new tab, http(s) only, no opener, no referrer
//   napplet:link/preview { url }                          -> { data: { title, description, siteName, image } | null }:
//                                                            the page's OpenGraph, read by the shell as the classic
//                                                            link card does (link-preview.js: public https only, CORS,
//                                                            no cookies, no referrer). Reader only: the napplet itself
//                                                            has no network, and no other napplet gets a fetcher.
//   napplet:note/repost|zap|menu { event }                -> the classic flows, run by the shell (gap run, after P8):
//                                                            repost with the Send Delay's Undo, the zap picker, the
//                                                            ⋯ menu (copy, bookmark, block, report, delete). The
//                                                            event must carry a valid signature: a napplet can't make
//                                                            the shell repost, zap or delete a note it made up.
//   shell -> Reader: napplet:note/open { id }, napplet:profile/open { pubkey }, napplet:feed/open
export const COMPOSE_DONE = "nv.compose.done"
/** Compose posted and the Send Delay counts down (hide the sheet so the pill's Undo can be reached), or it was undone
 *  (show it again, text intact). */
export const COMPOSE_WAITING = "nv.compose.waiting", COMPOSE_UNDONE = "nv.compose.undone"
import { READER_DTAG as READER } from "./first-party-list.js"
const HEX = /^[0-9a-f]{64}$/

/** A link a napplet asked to open -> the URL to open, or null. http(s) only, no user:pass, at most 2048 characters. */
export function linkTarget(raw) {
  if (typeof raw !== "string" || raw.length > 2048) return null
  let u
  try { u = new URL(raw) } catch { return null }
  if ((u.protocol !== "https:" && u.protocol !== "http:") || u.username || u.password) return null
  return u.href
}

/** Where a route opens the Reader: { archetype, action, payload } for #/thread/<id> or someone's #/profile/<pk>. */
export function readerOpenFor(route, arg) {
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

export function readerIntents({ bus, openCompose, onComposeDone, onComposeWaiting = () => {}, onComposeUndone = () => {}, openUrl, verify = () => false, onRepost = () => {}, onZap = () => {}, onMenu = () => {}, preview = async () => null }) {
  const on = { [COMPOSE_DONE]: onComposeDone, [COMPOSE_WAITING]: onComposeWaiting, [COMPOSE_UNDONE]: onComposeUndone }
  const me = { dTag: "shell", send: m => { if (m?.type === "inc.event" && on[m.topic]) on[m.topic](m.payload) } }
  for (const t of Object.keys(on)) bus.subscribe(me, t)
  const off = [
    bus.register({ id: "nv-compose", title: "Compose", archetype: "compose", actions: ["new", "reply", "quote"], conventions: [], open: openCompose }),
    ...[["repost", onRepost], ["zap", onZap], ["menu", onMenu]].map(([action, run]) => bus.register({ id: `shell-note-${action}`, title: action, archetype: "note", actions: [action], conventions: [], deliver: p => {
      const note = actionNote(p?.event, verify)
      if (!note) return { ok: false, error: "not a signed note" }
      run(note)
      return { ok: true }
    } })),
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
