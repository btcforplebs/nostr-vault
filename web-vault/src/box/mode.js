// Box mode: this web app as served by NV for Linux (the "nostr-vault-linux" container). Built with NV_BOX=1, the
// vault is the box itself, on the same origin as the page (its relay answers websockets on the same port), so the app
// works on the LAN or the mesh with no internet. The box screens (#/box) talk to its owner-only API under /api/box/.

/** Built for a box (vite.config.js defines __NV_BOX__ from NV_BOX=1). */
export const BOX = typeof __NV_BOX__ !== "undefined" && __NV_BOX__ === true

/** The box relay's websocket URL for a Haven route ("/", "/feed", "/inbox", "/chat", "/private"): the page's own origin. */
export function boxRelayUrl(route = "/", loc = globalThis.location) {
  const scheme = loc.protocol === "https:" ? "wss:" : "ws:"
  return `${scheme}//${loc.host}${route === "/" ? "/" : route}`
}

/** The box API's base URL: same origin. */
export const boxApiBase = (loc = globalThis.location) => `${loc.origin}/api/box`
