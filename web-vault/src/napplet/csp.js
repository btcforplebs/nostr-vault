// The napplet frame's own Content-Security-Policy, injected as a <meta> at the top of its srcdoc. Default deny: no
// network at all. Bytes come through NAP-RESOURCE as Blobs, so images and media may only be blob: or data:.
// Inline script and style are allowed because a napplet is one self-contained file.
export const frameCsp = () => [
  "default-src 'none'",
  "script-src 'unsafe-inline' 'unsafe-eval' blob:",
  "style-src 'unsafe-inline'",
  "img-src blob: data:",
  "media-src blob: data:",
  "font-src data:",
  "worker-src blob:",
  "connect-src 'none'",
  "form-action 'none'",
  "base-uri 'none'",
].join("; ")

// The loader page's header CSP (/vault/napplet-frame.html): the frame's rules, plus who may frame it. Served by
// website/nginx.conf (same string, checked by test/napplet-runtime.test.mjs), vite dev and server.mjs. The written
// napplet keeps this policy (document.write doesn't change a document's CSP), and its own <meta> one on top.
// `sandbox allow-scripts` repeats the iframe's own sandbox attribute in the header, so the loader stays opaque-origin
// with no navigation of its parent even if something frames it without one. It doesn't stop a napplet navigating its
// own frame (CSP has no navigate-to): see docs/napplets/P1_RUNTIME.md, "What 'no network' does not cover".
export const loaderCsp = () => `${frameCsp()}; frame-ancestors 'self'; sandbox allow-scripts`
export const LOADER_FILE = "napplet-frame.html"

// The napplet-origin loader (plan P2, origin.js): the same rules, a real origin (allow-same-origin is safe here: the
// origin is the napplet's own, never the vault's), its one service worker allowed, and only the vault may frame it.
// Same headers from vite dev and server.mjs (test-checked). `vault`: the vault's origin(s), space-separated.
export const SW_FILE = "napplet-sw.js"
export const isolatedLoaderCsp = ({ self, vault, base = "/vault/" }) =>
  frameCsp().replace("worker-src blob:", `worker-src blob: ${self}${base}${SW_FILE}`) +
  `; frame-ancestors ${vault}; sandbox allow-scripts allow-same-origin`
export const isolatedLoaderHeaders = ({ self, vault, base }) => ({
  "Content-Security-Policy": isolatedLoaderCsp({ self, vault, base }),
  "X-DNS-Prefetch-Control": "off",
  "Referrer-Policy": "no-referrer",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=(), display-capture=(), usb=(), serial=(), hid=(), bluetooth=(), payment=(), publickey-credentials-get=(), clipboard-read=()",
  "Cache-Control": "no-cache",
})

/** For vite dev and server.mjs: a request on a napplet origin -> { file, headers } for the two files it may have,
 *  or null (404: a napplet origin serves nothing else, never the app). `host` is the request's Host. */
export function nappletOriginFile(pathname, { host, proto = "http", base = "/vault/", vaultHosts }) {
  const self = `${proto}://${host}`
  const vault = vaultHosts.map(h => `${proto}://${h}`).join(" ")
  if (pathname === `${base}${LOADER_FILE}`) return { file: LOADER_FILE, type: "text/html", headers: isolatedLoaderHeaders({ self, vault, base }) }
  if (pathname === `${base}${SW_FILE}`) return { file: SW_FILE, type: "text/javascript", headers: { "Cache-Control": "no-cache", "Service-Worker-Allowed": base } }
  return null
}
