// Offline shell. Hashed build files (assets/, haven.wasm among them) never change, so they come from the cache once
// stored and are fetched only once. Everything else is network first, with the cached copy when offline, so a
// reload works without a network.
const C = "nv-web-vault-v2"
// A first install starts at once. A new build waits beside the worker serving open pages (whose lazy chunks
// activate's prune would drop) until a page asks: "Update ready, tap to reload" (src/sw-update.js).
self.addEventListener("install", e => e.waitUntil(precache().then(() => self.registration?.active ? undefined : self.skipWaiting())))
self.addEventListener("message", e => {
  if (e.data === "skip-waiting") self.skipWaiting()
  // The page asks before showing notifications through this worker: an older worker has no notificationclick.
  if (e.data === "nv-notify-ping") e.source?.postMessage({ type: "nv-notify-ready" })
})
self.addEventListener("activate", e => e.waitUntil(migrate().then(prune).then(() => self.clients.claim())))
// The first visit's page and scripts were fetched before this worker existed, so nothing above would have stored
// them: a reload offline right after the first visit fails. Stores the app shell now: index.html (served at the
// scope root) and every same-origin file it links (the hashed script and stylesheet, manifest, icons).
async function precache() {
  const index = new URL("./", location), res = await fetch(index, { cache: "no-cache" })
  if (!res.ok) throw new Error(`index ${res.status}`)
  const html = await res.clone().text()
  // The old worker keeps serving from this same cache while this one installs, so nothing goes in until every
  // file is in hand: the index last, after the files it links. A 404 or a dropped network fails the install and
  // leaves the cache as it was; a cached new index pointing at a script that isn't cached would be a blank app.
  const files = await Promise.all(shell(html, index).map(async u => {
    const r = await fetch(u, { cache: "no-cache" })
    if (!r.ok) throw new Error(`${u} ${r.status}`)
    return [u, r]
  }))
  for (const [u, r] of files) await store(new Request(u), r)
  await store(new Request(index), res)
}
// The same-origin URLs an index.html links (src="…" and href="…" of its tags).
function shell(html, base) {
  const out = new Set()
  for (const [, , v] of html.matchAll(/\s(src|href)=["']([^"']+)["']/g)) {
    const u = new URL(v, base)
    if (u.origin === base.origin && u.href !== base.href) out.add(u.href)
  }
  return [...out]
}
// Moves what the older caches hold into this one, then deletes them: the page open right now was served by
// the old worker, and must still reload offline before it has been fetched through this one.
async function migrate() {
  const c = await caches.open(C)
  for (const k of (await caches.keys()).filter(k => k.startsWith("nv-web-vault-") && k !== C)) {
    const o = await caches.open(k)
    for (const r of await o.keys()) if (!(await c.match(r))) await c.put(r, await o.match(r))
    await caches.delete(k)
  }
}
// Drops the hashed build files (assets/<name>-<hash>.js|css|wasm) the current index no longer reaches: every deploy
// left its scripts and styles here before (+1.2 MB a build, never pruned). Kept: what index.html links, and every
// hashed name those scripts mention (lazy chunks such as hls-*.js, the per-screen CSS, haven-*.wasm), followed
// through the cached scripts. Run on activate, after install stored the new index.
async function prune() {
  const c = await caches.open(C), base = new URL("./", location), index = await c.match(base.href)
  if (!index) return
  const keep = new Set(), queue = [await index.text()]
  while (queue.length) {
    for (const [name] of queue.pop().matchAll(BUILD_FILE)) {
      if (keep.has(name)) continue
      keep.add(name)
      if (name.endsWith(".js")) { const r = await c.match(new URL(`assets/${name}`, base).href, { ignoreSearch: true }); if (r) queue.push(await r.text()) }
    }
  }
  for (const k of await c.keys()) {
    const p = new URL(k.url).pathname, name = p.slice(p.lastIndexOf("/") + 1)
    if (p.includes("/assets/") && BUILD_NAME.test(name) && !keep.has(name)) await c.delete(k)
  }
}
const BUILD_FILE = /[\w-]+-[\w-]{8}\.(?:js|css|wasm)/g, BUILD_NAME = new RegExp(`^${BUILD_FILE.source}$`)

self.addEventListener("fetch", e => {
  const u = new URL(e.request.url)
  if (e.request.method !== "GET" || u.origin !== location.origin) return
  const asset = u.pathname.includes("/assets/")
  // A missing asset comes back as index.html (the server's fallback); never keep that under the asset's name.
  const net = () => fetch(e.request).then(r => {
    if (r.ok && !(asset && /^text\/html/.test(r.headers.get("Content-Type")))) e.waitUntil(store(e.request, r.clone()))
    return r
  })
  if (asset) return e.respondWith(caches.match(e.request, { ignoreSearch: true }).then(hit => hit || net()))
  // Offline, a page URL not seen before (a deep link, a stale tab) gets the shell, as the server would send index.html.
  const shellPage = () => e.request.mode === "navigate" ? caches.match(new URL("./", location).href) : undefined
  e.respondWith(net().catch(async () => (await caches.match(e.request, { ignoreSearch: true })) || shellPage()))
})

// Unchanged files (same ETag) aren't rewritten. A new build's hashed .wasm replaces its older versions
// (haven-<hash>.wasm drops the previous haven-<hash>.wasm), so the cache holds one haven.wasm, not one per build.
async function store(req, res) {
  const c = await caches.open(C), old = await c.match(req, { ignoreSearch: true })
  if (old && res.headers.get("ETag") && old.headers.get("ETag") === res.headers.get("ETag")) return
  await c.put(req, res)
  const name = hashed(new URL(req.url).pathname)
  if (name) for (const k of await c.keys()) if (k.url !== req.url && hashed(new URL(k.url).pathname) === name) await c.delete(k)
}
// "/vault/assets/haven-CQm0vJnR.wasm" -> "/vault/assets/haven.wasm". Only .wasm: one build can hold two
// index-<hash>.js chunks, but not two haven-<hash>.wasm, and the wasm files are the ones worth pruning.
const hashed = p => p.includes("/assets/") && p.match(/^(.*)-[\w-]{8}(\.wasm)$/)?.slice(1).join("") || null

// A notification the page showed (src/net/notify-show.js; no push, the page was open): a click focuses an open tab of
// the app and tells it where to go, or opens the app there when no tab is left.
self.addEventListener("notificationclick", e => {
  e.notification.close()
  const href = e.notification.data?.href
  const route = typeof href === "string" && href.startsWith("#/") ? href : ""
  e.waitUntil((async () => {
    const tabs = await self.clients.matchAll({ type: "window", includeUncontrolled: true })
    const tab = tabs.find(c => new URL(c.url).pathname.startsWith(new URL("./", location).pathname))
    if (tab) {
      await tab.focus().catch(() => {})
      if (route) tab.postMessage({ type: "nv-open", href: route })
      return
    }
    await self.clients.openWindow(new URL(`./${route}`, location).href)
  })())
})
