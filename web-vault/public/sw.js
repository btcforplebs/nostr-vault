// Offline shell: network first for same-origin GETs, the cached copy when offline, so a reload works without a network.
const C = "nv-web-vault-v1"
self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()))
self.addEventListener("fetch", e => {
  const u = new URL(e.request.url)
  if (e.request.method !== "GET" || u.origin !== location.origin) return
  e.respondWith(fetch(e.request).then(r => { const c = r.clone(); if (r.ok) caches.open(C).then(x => x.put(e.request, c)); return r })
    .catch(() => caches.match(e.request, { ignoreSearch: true })))
})
