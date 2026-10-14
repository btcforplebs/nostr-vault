// Minimal offline shell. Hashed build files (assets/) never change, so they come from the cache once stored.
// Everything else (haven.wasm included: its name has no hash) is network first, and the server answers an unchanged
// file with 304, so a reload doesn't download it again. The cached copy is used when offline.
const C = 'nv-web-relay-v2'
self.addEventListener('install', e => self.skipWaiting())
self.addEventListener('activate', e => e.waitUntil(migrate().then(() => self.clients.claim())))
// Moves what the older caches hold into this one, then deletes them: the page open right now was served by
// the old worker, and must still reload offline before it has been fetched through this one.
async function migrate() {
  const c = await caches.open(C)
  for (const k of (await caches.keys()).filter(k => k.startsWith('nv-web-relay-') && k !== C)) {
    const o = await caches.open(k)
    for (const r of await o.keys()) if (!(await c.match(r))) await c.put(r, await o.match(r))
    await caches.delete(k)
  }
}
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url)
  if (e.request.method !== 'GET' || u.origin !== location.origin || u.pathname.endsWith('/beacon')) return
  const asset = u.pathname.includes('/assets/')
  // A missing asset comes back as index.html (the server's fallback); never keep that under the asset's name.
  const net = () => fetch(e.request).then(r => {
    if (r.ok && !(asset && /^text\/html/.test(r.headers.get('Content-Type')))) e.waitUntil(store(e.request, r.clone()))
    return r
  })
  if (asset) return e.respondWith(caches.match(e.request).then(hit => hit || net()))
  e.respondWith(net().catch(() => caches.match(e.request)))
})

// Unchanged files (same ETag) aren't rewritten; a new build's hashed .wasm replaces its older versions.
async function store(req, res) {
  const c = await caches.open(C), old = await c.match(req)
  if (old && res.headers.get('ETag') && old.headers.get('ETag') === res.headers.get('ETag')) return
  await c.put(req, res)
  const name = hashed(new URL(req.url).pathname)
  if (name) for (const k of await c.keys()) if (k.url !== req.url && hashed(new URL(k.url).pathname) === name) await c.delete(k)
}
const hashed = p => p.includes('/assets/') && p.match(/^(.*)-[\w-]{8}(\.wasm)$/)?.slice(1).join('') || null
