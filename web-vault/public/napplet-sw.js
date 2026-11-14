// The napplet origin's service worker (plan P2; public/napplet-frame.html registers it, src/napplet/origin.js). A
// napplet origin serves only its loader page and this file; every other request from the napplet's frame (fetch, an
// image, a worker script, anything the frame's CSP might let past) gets a network error here, before the network.
// Not the vault's sw.js: that one lives on the vault's own origin and never sees a napplet.
const OWN = /\/(napplet-frame\.html|napplet-sw\.js)$/
self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()))
self.addEventListener("fetch", e => {
  const u = new URL(e.request.url)
  if (u.origin === location.origin && OWN.test(u.pathname) && !u.search) return
  e.respondWith(Response.error())
})
