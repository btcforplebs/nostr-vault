// The Reader pane's side of the bus (plan P4): what the Reader napplet may ask the shell for, and how the shell opens a
// note or a profile in it. Pure apart from the callbacks, so node tests drive it with a fake bus participant.
//   napplet:compose/new, napplet:compose/reply { event }  -> the Compose napplet (openCompose mounts it in a sheet)
//   napplet:link/open { url }                             -> a new tab, http(s) only, no opener, no referrer
//   shell -> Reader: napplet:note/open { id }, napplet:profile/open { pubkey }, napplet:feed/open
export const COMPOSE_DONE = "nv.compose.done"
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
export function readerIntents({ bus, openCompose, onComposeDone, openUrl }) {
  const me = { dTag: "shell", send: m => { if (m?.type === "inc.event" && m.topic === COMPOSE_DONE) onComposeDone(m.payload) } }
  bus.subscribe(me, COMPOSE_DONE)
  const off = [
    bus.register({ id: "nv-compose", title: "Compose", archetype: "compose", actions: ["new", "reply"], conventions: [], open: openCompose }),
    bus.register({ id: "shell-link", title: "Open link", archetype: "link", actions: ["open"], conventions: [], deliver: p => {
      const url = linkTarget(p?.url)
      if (!url) return { ok: false, error: "not an http(s) link" }
      openUrl(url)
      return { ok: true }
    } }),
  ]
  return { me, close: () => { bus.forget(me); off.forEach(f => f()) } }
}
