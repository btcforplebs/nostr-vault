// /v3/ is retired: the 3.0 web app is /vault/ (website/nginx.conf sends /v3/ there). A browser that ran /v3/ still has
// its worker, which would keep serving the old app from cache; its next update check gets this file instead. It
// unregisters itself and sends any open /v3/ tab to /vault/. The caches stay: /vault/'s worker uses the same one.
self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", e => e.waitUntil((async () => {
  await self.registration.unregister()
  for (const c of await self.clients.matchAll({ type: "window" })) c.navigate(c.url.replace("/v3/", "/vault/"))
})()))
