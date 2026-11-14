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
