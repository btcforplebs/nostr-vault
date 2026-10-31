// Showing a notification and opening what it is about. Through the app's own service worker (public/sw.js) when it
// has one: registration.showNotification works in every browser that has it, and is the only way Chrome on Android
// shows one (`new Notification` throws there). The worker's notificationclick focuses an open app tab and tells it
// where to go, or opens one. No push: the page decides what to show, while it is open.
// Without a worker (it isn't registered yet, or this browser has none), `new Notification` and its onclick.

export const OPEN_MESSAGE = "nv-open"

// Whether the worker serving this page opens a clicked notification (one from before this build doesn't). Asked once.
let workerClicks = null
/** Asks the active worker once; resolves true when it answers. `wait` ms at most. */
export function askWorker(sw = globalThis.navigator?.serviceWorker, wait = 3000) {
  if (workerClicks) return workerClicks
  if (!sw?.controller) return Promise.resolve(false)
  workerClicks = new Promise(resolve => {
    const done = ok => { sw.removeEventListener("message", on); clearTimeout(t); if (!ok) workerClicks = null; resolve(ok) }
    const on = e => { if (e.data?.type === "nv-notify-ready") done(true) }
    const t = setTimeout(() => done(false), wait)
    sw.addEventListener("message", on)
    sw.controller.postMessage("nv-notify-ping")
  })
  return workerClicks
}

/**
 * Shows `n` ({ title, body, tag, href }). `sw` (navigator.serviceWorker) and `N` (Notification) are for tests.
 * -> "worker" | "page" | "none"
 */
export async function showNotice(n, { sw = globalThis.navigator?.serviceWorker, N = globalThis.Notification, icon = "./icon-192.png" } = {}) {
  const opts = { body: n.body, tag: n.tag, icon, data: { href: n.href } }
  // The worker when it opens clicks, or when the page can't show one itself (Chrome on Android).
  const viaWorker = sw?.controller && (typeof N !== "function" || await askWorker(sw))
  const reg = viaWorker ? await sw.getRegistration?.().catch(() => null) : null
  if (reg?.showNotification) {
    try { await reg.showNotification(n.title, opts); return "worker" } catch {}
  }
  if (typeof N !== "function") return "none"
  try {
    const note = new N(n.title, opts)
    if (!note) return "none"
    note.onclick = () => { try { globalThis.focus?.() } catch {} openHref(n.href); note.close?.() }
    return "page"
  } catch {
    // Chrome on Android: only a worker can show one. An older worker can't open the click, but it can show it.
    const r = sw?.controller && !reg ? await sw.getRegistration?.().catch(() => null) : null
    if (r?.showNotification) { try { await r.showNotification(n.title, opts); return "worker" } catch {} }
    return "none"
  }
}

/** Goes to `href` (a "#/…" route) in this page. */
export const openHref = href => { if (typeof href === "string" && href.startsWith("#/")) globalThis.location.hash = href }

/** Listens for the worker's "open this" after a notification click. -> stop */
export function listenNoticeClicks(sw = globalThis.navigator?.serviceWorker) {
  if (!sw?.addEventListener) return () => {}
  const on = e => { if (e.data?.type === OPEN_MESSAGE) openHref(e.data.href) }
  sw.addEventListener("message", on)
  return () => sw.removeEventListener("message", on)
}

/** Sign-out closes the notifications this page has showing (the iPhone clears its delivered ones), so a signed-out
 *  account's names and messages don't stay in the system tray. */
export async function closeShownNotices(sw = globalThis.navigator?.serviceWorker) {
  try {
    const reg = await sw?.getRegistration?.()
    for (const n of (await reg?.getNotifications?.()) ?? []) n.close()
  } catch {}
}
