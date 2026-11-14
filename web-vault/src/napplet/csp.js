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
export const loaderCsp = () => `${frameCsp()}; frame-ancestors 'self'`
export const LOADER_FILE = "napplet-frame.html"
