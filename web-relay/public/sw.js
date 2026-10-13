// Minimal offline shell: cache-first for same-origin GETs so reloads work without the server.
const C = 'nv-web-relay-v1'
self.addEventListener('install', e => self.skipWaiting())
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()))
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url)
  if (e.request.method !== 'GET' || u.origin !== location.origin || u.pathname.endsWith('/beacon')) return
  e.respondWith(fetch(e.request).then(r => { const c = r.clone(); caches.open(C).then(x => x.put(e.request, c)); return r })
    .catch(() => caches.match(e.request)))
})
